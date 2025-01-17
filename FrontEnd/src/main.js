import Vue from 'vue';
import App from '@/App/App.vue';
import router from './router';
import store from './store';
// import { connect, } from 'mqtt';
import LocalStorage, { Keys,ConnectedWallet,} from '@/utils/localStorage.js';
import EventBus, { EventNames, } from '@/eventBuses/default';
import { uuidv4, } from './utils/utility';

import BootstrapVue from 'bootstrap-vue';
import 'bootstrap/dist/css/bootstrap.css';
import 'bootstrap-vue/dist/bootstrap-vue.css';

import '@vuikit/theme';
import '@/assets/scss/base/icons.scss';
import ApolloClient from 'apollo-client';     //Apollo GraphQL
import {WebSocketLink,} from 'apollo-link-ws'; //Apollo GraphQL
import { HttpLink } from 'apollo-link-http';
import { InMemoryCache, } from 'apollo-cache-inmemory';  //Apollo GraphQL
import VueApollo from 'vue-apollo';   //Vue-Apollo plugin
// import ApolloClient from "apollo-boost";  //BETTER
import '@/assets/scss/base/colors.scss';
import '@/assets/scss/base/core.scss';
import '@/assets/scss/base/typography.scss';
import '@/assets/scss/base/form-field.scss';
import '@/assets/scss/base/buttons.scss';
import '@/assets/scss/base/checkbox.scss';
import '@/assets/scss/base/containers.scss';
import '@/assets/scss/base/tables.scss';
import '@/assets/scss/base/scrollbar.scss';
import '@/assets/scss/base/panel.scss';
import '@/assets/scss/uk-overrides/modal.scss';
import '@/assets/scss/uk-overrides/subnav.scss';
import '@/assets/scss/uk-overrides/button.scss';
import '@/assets/scss/uk-overrides/tabs.scss';
import '@/assets/css/core.css';
import '@/assets/css/simplebar.css';
import '@/assets/css/colors.css';

import AsyncComputed from 'vue-async-computed';

// We area Link to connect ApolloClient with the GraphQL server.  
// Subsequently, we instantiate ApolloClient 
// by passing in our Link and a new instance of InMemoryCache (recommended caching solution). Finally, 
// we are adding ApolloProvider to the Vue app.

// const header = { Authorization: 'Bearer ' + ConnectedWallet.token, };
  //Link for Subscription and defining headers
  const graphQL_subscription = new WebSocketLink({ uri: 'wss://api.thegraph.com/subgraphs/name/cryptowhaler/sigh-finance-kovan', options: { reconnect: true, timeout:300000, }, });
  const subscriptionClient = new ApolloClient({ link: graphQL_subscription, cache: new InMemoryCache({ addTypename: true, }),});

  Vue.use(VueApollo);

  /* Init Bootstrap */
  Vue.use(BootstrapVue);
  Vue.use(AsyncComputed);  // Plugin to make async calls in computed 

  const apolloProvider = new VueApollo({  //holds the Apollo client instances that can then be used by all the child components
    defaultClient: subscriptionClient,
  });

  if (!LocalStorage.get(Keys.pingUuid)) {       
    LocalStorage.set(Keys.pingUuid, uuidv4());
  }

  Vue.config.productionTip = false;

  new Vue({
    router,
    store,
    apolloProvider,
    render: h => h(App),
  }).$mount('#app');
