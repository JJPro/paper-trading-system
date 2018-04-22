import React from 'react';
import { render } from 'react-dom';
import { BrowserRouter as Router, Route, Switch, NavLink } from 'react-router-dom';
import { Provider, connect } from 'react-redux';
import store from '../redux/store';
import api from '../redux/api';

import ActionPanel from './action-panel';
import AlertPanel from './alert-panel';
import Watchlist from './watchlist';
import Alerts from './alerts';

import socket from '../socket';

export default (root) => {
  render(
    <Provider store={store} >
      <Index />
    </Provider>,
    root
  );
};


let Index = connect(state => state)( props => {

  window.store = store; // TODO for debugging purposes
  let style = {};
  
  return (
    <Router>
      <div>
        <NavLink to="/" exact >Watchlist </NavLink>
        |
        <NavLink to="/alerts" exact > Alerts</NavLink>
        <Switch>
          <Route path="/" exact component={Watchlist} />}
          <Route path="/alerts" exact component={Alerts} />
        </Switch>
        <ActionPanel />
        <AlertPanel />
      </div>
    </Router>
  );
});
