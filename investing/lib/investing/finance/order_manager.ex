defmodule Investing.Finance.OrderManager do
  @moduledoc """
  Order Service management

  This module is part of the paper trading system.
  (Ref: Issue #3: https://github.com/JJPro/paper-trading-system/issues/3)

  Role:
  1. Monitors pending orders and executes them when target price is reached.
  2. May split a realized order into another pending order if this is a limit order.
     Currently the system only supports _buy limit order_.

  (Ref: [What is a limit order?](https://en.wikipedia.org/wiki/Order_(exchange)#Limit_order))
  """
  use GenServer
  alias Investing.{Finance, Accounts}
  alias Investing.Finance.{ThresholdManager, Order, Holding}
  # alias Investing.Utils.Actions
  require Logger


### Public Interface: ###
  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Places new order.

  ## NOTE
  This creates db entry, only call this when server is live, and let this function handle db and server operations
    - creates db entry
    - requests to monitor order
  """
  @spec place_order(%Order{}) :: nil
  def place_order(order) do
    {:ok, order} = Finance.create_order(order) # create db entry

    add_order(order)   # add to order manager daemon to monitor

    InvestingWeb.Endpoint.broadcast! "orders:#{order.user_id}", "order_placed", %{order: order}
    if order.action == "buy" do # update usable balance
      Logger.info("broadcasting to action panel to update balance after placing order")
      InvestingWeb.Endpoint.broadcast! "action_panel:#{order.user_id}", "update_balance", %{type: :usable, action: :subtract, amt: order.target * order.quantity}
    end

  end

  @spec cancel_order(%Order{}) :: nil
  def cancel_order(order) do
    Logger.debug("canceling order in order manager")
    {:ok, order} = Finance.update_order(order, %{status: "canceled"})

    del_order(order)   # remove order from this daemon

    InvestingWeb.Endpoint.broadcast! "orders:#{order.user_id}", "order_canceled", %{order: order}
    if order.action == "buy" do # update usable balance
      Logger.info("broadcasting to action panel to update balance after canceling order")
      InvestingWeb.Endpoint.broadcast! "action_panel:#{order.user_id}", "update_balance", %{type: "usable", action: :add, amt: order.target * order.quantity}
    end
  end


  ##
  # pass a new order to the service to monitor
  #
  # ## Parameters
  #
  #   - order: Order object
  ##
  defp add_order(order) do
    GenServer.cast(__MODULE__, {:add_order, order})
  end

  ##
  # delete an order from the service
  #
  # ## Parameters
  #   - order: Order object to delete
  ##
  @spec del_order(Order) :: nil
  defp del_order(order) do
    GenServer.cast(__MODULE__, {:del_order, order})
  end

### GenServer Implementations ###
  @doc """
  Triggerred during module startup.
  1. setup server state, loads pending orders from database.
  2. subscribe to threshold_manager daemon

  ## Return
    - {:ok, %{"symbol1" => [order list], "symbol2" => [order list], ...}}
  """
  @spec init(List.t()) :: {:ok, map()}
  def init(_state) do
    active_orders = Finance.list_active_orders()

    # subscribe to threshold manager daemon
    initial_state = Enum.reduce(active_orders, %{},
    fn (order, acc) ->
      ThresholdManager.subscribe(order.symbol, condition(order), self(), true) # step 2.

      {_, new_acc} = Map.get_and_update(acc, order.symbol, fn orders ->
        if is_nil(orders), do: {nil, [order]}, else: {nil, [order|orders]}
      end)
      new_acc
    end) # Step 1.

    {:ok, initial_state}
  end

  def terminate(_reason, state) do
    {:shutdown, state}
  end

  ##
  # handling :threshold_met message from ThresholdManager daemon
  # This function will be called to execute the order.
  #
  # Description:
  #   find all satisfied orders, execute them and remove them from server state.
  def handle_cast({:threshold_met, %{symbol: symbol, price: price, condition: condition}}, state) when is_number(price) do

    new_state =
      state
      |> Map.update!(symbol, fn orders ->

        Enum.reject(orders, fn order ->
          cond do
            condition(order) == condition -> # order is matched
              execute_order(order, price)
              true

            true -> false
          end
        end)

      end)
    {:noreply, new_state}
  end

  ##
  # Adds a new order to system while the system is already running.
  #
  # ## Parameters
  #   - order: Order object
  #   - state: current state of this server.
  #            state is of data format:
  #            %{"symbol" => [list of pending orders]}
  def handle_cast({:add_order, order}, state) do
    ThresholdManager.subscribe(order.symbol, condition(order), self(), true)

    {_, new_state} = Map.get_and_update(state, order.symbol, fn orders ->
      if is_nil(orders), do: {nil, [order]}, else: {nil, [order|orders]}
    end)

    {:noreply, new_state}
  end

  ##
  # delete an order from the system.
  # This is triggerred when user manually deletes an active order,
  # needs to do the following:
  # 1. remove this order from server state;
  # 2. unsubscribe from threshold service if there is no orders of the same condition and symbol
  #
  # ## Parameters
  #   - order: Order object to delete
  #   - state: current state of this server.
  #            state is of data format:
  #            %{"symbol" => [list of pending orders]}
  def handle_cast({:del_order, order}, state) do
    {_, new_state} = Map.get_and_update(state, order.symbol, fn orders ->
      if is_nil(orders) do # WARNING: this shouldn't happen, state is outta sync if this happens
        IO.warn("in #{__MODULE__}, order state is out of sync")
        {nil, []}
      else
        new_orders = Enum.reject(orders, &(&1.id == order.id) ) # Step 1.
        if not Enum.any?(new_orders, &(condition(&1) == condition(order))) do
          ThresholdManager.unsubscribe(order.symbol, condition(order), self()) # Step 2.
        end
        {nil, new_orders} # Step 1.
      end
    end) # Step 1

    {:noreply, new_state}
  end

  ##
  # Places a buy-stoploss order.
  #
  # Do the following:
  # 1. set order status to be "executed" in db
  # 2. place sell order for the stop loss
  # 3. update user balance
  # 4. create holding record for the order
  @spec execute_order(Order.t(), float) :: nil

  # when this is a buy-stoploss order
  defp execute_order(
    order = %Order{stoploss: stoploss, action: action},
    price
  )
  # TODO check what the stoploss value is when not provided on creation, is it NULL or 0?
  #       and revision of this block might be necessary accordingly
  when action == "buy" and not (is_nil(stoploss) or stoploss == 0)
  do
    Logger.info("stoploss = #{stoploss}")

    order = order
    |> update_order_status() # 1.
    |> update_account_balance(price) # 3.
    |> update_holding_position(price) # 4.

    # 2. place a sell order for the stoploss part
    _sell_order =
    %Order{ order | action: "sell", target: order.stoploss, stoploss: nil}
    |> place_order()
  end

  # this is a normal order (sell or buy)
  defp execute_order(order = %Order{}, price) do
    order = order
    |> update_order_status()
    |> update_account_balance(price)
    |> update_holding_position(price)

    InvestingWeb.Endpoint.broadcast! "orders:#{order.user_id}", "order_executed", %{order: order, at_price: price, condition: condition(order)}
  end

  # Description:
  # two cases depends on order type:
  #   buy order -> create holding record
  #   sell order -> delete holding record
  # then notify whoever care about this change via actions
  @spec update_holding_position(Order, float) :: Order
  defp update_holding_position(order = %Order{action: "buy"}, trading_price) do

    # create holding record
    {:ok, %Holding{} = holding} = Finance.create_holding(
      %{
        symbol: order.symbol,
        bought_at: trading_price,
        quantity: order.quantity,
        user_id: order.user_id
      })

    # trigger action
    InvestingWeb.Endpoint.broadcast! "action_panel:#{holding.user_id}", "holding_updated", %{holding: holding, action: :increase}

    # notify holding_channel to subscribe to live quote of this symbol
    Phoenix.PubSub.broadcast!(Investing.PubSub, "holdings:#{holding.user_id}", {:subscribe_symbol, holding.symbol})

    order
  end
  defp update_holding_position(order = %Order{action: "sell"}, _trading_price) do

    # Do the following:
    #   collect all holdings about this symbol, sorted by creation time
    #   decrease or delete holdings in chronological order
    holdings =
      Finance.list_user_holdings_for_symbol_sorted_by_creation_time(order.user_id, order.symbol)
      |> IO.inspect(label: ">>>>> all holdings for symbol #{order.symbol}")

    holding_quantity_to_decrease = order.quantity

    _decrease_holdings(holdings, holding_quantity_to_decrease)

    order
  end

  defp _decrease_holdings(_, 0), do: nil
  defp _decrease_holdings([], qty_to_decrease) when qty_to_decrease > 0, do: Logger.error("decrease on empty holdings")
  defp _decrease_holdings([], _), do: nil
  defp _decrease_holdings([holding = %Holding{quantity: qty}|rest], qty_to_decrease) when qty_to_decrease >= qty do
    # remove holding record
    Finance.delete_holding(holding)
    InvestingWeb.Endpoint.broadcast! "action_panel:#{holding.user_id}", "holding_updated", %{holding: holding, action: :delete}

    # notify holdings channel to unsub from live quotes if there is no more
    # holdings of the same symbol
    if __last_holding_of_the_symbol?(holding) do
      Phoenix.PubSub.broadcast!(Investing.PubSub, "holdings:#{holding.user_id}", {:unsubscribe_symbol, holding.symbol})
    end

    qty_to_decrease = qty_to_decrease - qty
    _decrease_holdings(rest, qty_to_decrease)
  end
  # qty_to_decrease < holding.quantity
  defp _decrease_holdings([holding = %Holding{quantity: qty}|_], qty_to_decrease) do
    # decrease holding record
    updated_holding_qty = qty - qty_to_decrease
    Finance.update_holding(holding, %{quantity: updated_holding_qty})
    InvestingWeb.Endpoint.broadcast! "action_panel:#{holding.user_id}", "holding_updated", %{holding: holding, action: :decrease, amt: qty_to_decrease}
  end

  defp __last_holding_of_the_symbol?(holding) do
    user = Accounts.get_user!(holding.user_id)
            |> Investing.Repo.preload(:holdings)

    Enum.any?(user.holdings, &(&1.symbol == holding.symbol))
  end


  @spec update_order_status(Order.t()) :: nil
  defp update_order_status(order = %Order{}) do
    {:ok, order} = Finance.update_order(order, %{status: "executed"})
    order
  end



  ##
  # calculate the appropriate condition string for a given order.
  ##
  @spec condition(Order) :: String.t()
  defp condition(order) do
    case order.action do
      "buy" -> "<= #{order.target}"
      "sell" -> ">= #{order.target}"
    end
  end

  defp update_account_balance(order, price) do
    # update user account balance with processed order and trading price.
    action = case order.action do
      "buy" -> :subtract
      "sell" -> :add
    end
    change_amt = price * order.quantity
    _new_balance = Finance.update_user_balance(order.user_id, action, change_amt)
    InvestingWeb.Endpoint.broadcast! "action_panel:#{order.user_id}", "update_balance", %{type: :total, action: action, amt: change_amt}

    order
  end

end
