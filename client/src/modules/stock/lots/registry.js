angular.module('bhima.controllers')
  .controller('StockLotsController', StockLotsController);

StockLotsController.$inject = [
  'StockService', 'NotifyService',
  'uiGridConstants', 'StockModalService', 'LanguageService', 'GridGroupingService',
  'GridStateService', 'GridColumnService', '$state', '$httpParamSerializer',
  'SessionService',
];

/**
 * Stock lots Controller
 * This module is a registry page for stock lots
 */
function StockLotsController(
  Stock, Notify,
  uiGridConstants, Modal, Languages, Grouping,
  GridState, Columns, $state, $httpParamSerializer,
  Session
) {
  const vm = this;
  const cacheKey = 'lot-grid';
  const stockLotFilters = Stock.filter.lot;

  // grouping box
  vm.groupingBox = [
    { label : 'STOCK.INVENTORY', value : 'text' },
    { label : 'STOCK.INVENTORY_GROUP', value : 'group_name' },
  ];

  // grid columns
  const columns = [{
    field : 'depot_text',
    displayName : 'STOCK.DEPOT',
    headerCellFilter : 'translate',
  }, {
    field : 'code',
    displayName : 'STOCK.CODE',
    headerCellFilter : 'translate',
    sort : {
      direction : uiGridConstants.ASC,
      priority : 0,
    },
  }, {
    field : 'text',
    displayName : 'STOCK.INVENTORY',
    headerCellFilter : 'translate',
    sort : {
      direction : uiGridConstants.ASC,
      priority : 1,
    },
  }, {
    field : 'group_name',
    displayName : 'TABLE.COLUMNS.INVENTORY_GROUP',
    headerCellFilter : 'translate',
  }, {
    field : 'label',
    displayName : 'STOCK.LOT',
    headerCellFilter : 'translate',
  }, {
    field : 'quantity',
    displayName : 'STOCK.QUANTITY',
    headerCellFilter : 'translate',
  }, {
    field : 'unit_cost',
    displayName : 'STOCK.UNIT_COST',
    headerCellFilter : 'translate',
    type : 'number',
    cellFilter : 'currency: '.concat(Session.enterprise.currency_id),
  }, {
    field : 'unit_type',
    width : 75,
    displayName : 'TABLE.COLUMNS.UNIT',
    headerCellFilter : 'translate',
    cellTemplate : 'modules/stock/inventories/templates/unit.tmpl.html',
  }, {
    field : 'entry_date',
    displayName : 'STOCK.ENTRY_DATE',
    headerCellFilter : 'translate',
    cellFilter : 'date',
  }, {
    field : 'expiration_date',
    displayName : 'STOCK.EXPIRATION_DATE',
    headerCellFilter : 'translate',
    cellFilter : 'date',
  }, {
    field : 'delay_expiration',
    displayName : 'STOCK.EXPIRATION',
    headerCellFilter : 'translate',
  }, {
    field : 'avg_consumption',
    displayName : 'STOCK.CMM',
    headerCellFilter : 'translate',
    type : 'number',
  }, {
    field : 'S_MONTH',
    displayName : 'STOCK.MSD',
    headerCellFilter : 'translate',
    type : 'number',
  }, {
    field : 'lifetime',
    displayName : 'STOCK.LIFETIME',
    headerCellFilter : 'translate',
    cellTemplate     : 'modules/stock/lots/templates/lifetime.cell.html',
    type : 'number',
    sort : {
      direction : uiGridConstants.ASC,
      priority : 2,
    },
  }, {
    field : 'S_LOT_LIFETIME',
    displayName : 'STOCK.LOT_LIFETIME',
    headerCellFilter : 'translate',
    cellTemplate     : 'modules/stock/lots/templates/lot_lifetime.cell.html',
    type : 'number',
  }, {
    field : 'S_RISK',
    displayName : 'STOCK.RISK',
    headerCellFilter : 'translate',
    cellTemplate     : 'modules/stock/lots/templates/risk.cell.html',
    type : 'number',
    sort : {
      direction : uiGridConstants.DESC,
      priority : 3,
    },
  }, {
    field : 'S_RISK_QUANTITY',
    displayName : 'STOCK.RISK_QUANTITY',
    headerCellFilter : 'translate',
    cellTemplate     : 'modules/stock/lots/templates/risk_quantity.cell.html',
    type : 'number',
  }];

  const gridFooterTemplate = `
    <div>
      <b>{{ grid.appScope.countGridRows() }}</b>
      <span translate>TABLE.AGGREGATES.ROWS</span>
    </div>
  `;

  // options for the UI grid
  vm.gridOptions = {
    appScopeProvider : vm,
    enableColumnMenus : false,
    columnDefs : columns,
    enableSorting : true,
    showColumnFooter : true,
    fastWatch : true,
    flatEntityAccess : true,
    showGridFooter : true,
    gridFooterTemplate,
    onRegisterApi,
  };

  const gridColumns = new Columns(vm.gridOptions, cacheKey);
  const state = new GridState(vm.gridOptions, cacheKey);

  // expose to the view model
  vm.grouping = new Grouping(vm.gridOptions, false, 'depot_text', true, true);

  vm.getQueryString = Stock.getQueryString;
  vm.clearGridState = clearGridState;
  vm.search = search;
  vm.openColumnConfigModal = openColumnConfigModal;
  vm.loading = false;
  vm.saveGridState = state.saveGridState;

  function onRegisterApi(gridApi) {
    vm.gridApi = gridApi;
  }

  // count data rows
  vm.countGridRows = () => vm.gridOptions.data.length;

  // select group
  vm.selectGroup = (group) => {
    if (!group) { return; }
    vm.selectedGroup = group;
  };

  // toggle group
  vm.toggleGroup = (column) => {
    if (vm.grouped) {
      vm.grouping.removeGrouping(column);
      vm.grouped = false;
    } else {
      vm.grouping.changeGrouping(column);
      vm.grouped = true;
    }
  };

  // initialize module
  function startup() {
    if ($state.params.filters.length) {
      stockLotFilters.replaceFiltersFromState($state.params.filters);
      stockLotFilters.cache.formatCache();
    }

    load(stockLotFilters.formatHTTP(true));
    vm.latestViewFilters = stockLotFilters.formatView();
  }

  /**
   * @function errorHandler
   *
   * @description
   * Uses Notify to show an error in case the server sends back an information.
   * Triggers the error state on the grid.
   */
  function errorHandler(error) {
    vm.hasError = true;
    Notify.handleError(error);
  }

  /**
   * @function toggleLoadingIndicator
   *
   * @description
   * Toggles the grid's loading indicator to eliminate the flash when rendering
   * lots movements and allow a better UX for slow loads.
   */
  function toggleLoadingIndicator() {
    vm.loading = !vm.loading;
  }

  function orderByDepot(rowA, rowB) {
    return rowA.depot_text > rowB.depot_text ? 1 : -1;
  }

  // load stock lots in the grid
  function load(filters) {
    vm.hasError = false;
    toggleLoadingIndicator();

    // no negative or empty lot
    filters.includeEmptyLot = 0;

    Stock.lots.read(null, filters)
      .then((lots) => {

        // FIXME(@jniles): we should do this ordering on the server via an ORDER BY
        lots
          .sort(orderByDepot);

        vm.gridOptions.data = lots;

        vm.grouping.unfoldAllGroups();
        vm.gridApi.core.notifyDataChange(uiGridConstants.dataChange.COLUMN);
      })
      .catch(errorHandler)
      .finally(toggleLoadingIndicator);
  }

  // remove a filter with from the filter object, save the filters and reload
  vm.onRemoveFilter = function onRemoveFilter(key) {
    stockLotFilters.remove(key);
    stockLotFilters.formatCache();
    vm.latestViewFilters = stockLotFilters.formatView();
    return load(stockLotFilters.formatHTTP(true));
  };

  function search() {
    const filtersSnapshot = stockLotFilters.formatHTTP();

    Modal.openSearchLots(filtersSnapshot)
      .then((changes) => {
        stockLotFilters.replaceFilters(changes);
        stockLotFilters.formatCache();
        vm.latestViewFilters = stockLotFilters.formatView();
        return load(stockLotFilters.formatHTTP(true));
      });
  }

  // This function opens a modal through column service to let the user toggle
  // the visibility of the lots registry's columns.
  function openColumnConfigModal() {
    // column configuration has direct access to the grid API to alter the current
    // state of the columns - this will be saved if the user saves the grid configuration
    gridColumns.openConfigurationModal();
  }

  // saves the grid's current configuration
  function clearGridState() {
    state.clearGridState();
    $state.reload();
  }

  vm.downloadExcel = () => {
    const filterOpts = stockLotFilters.formatHTTP();
    const defaultOpts = {
      renderer : 'xlsx',
      lang : Languages.key,
      renameKeys : true,
      displayNames : gridColumns.getDisplayNames(),
    };
    // combine options
    const options = angular.merge(defaultOpts, filterOpts);
    // return  serialized options
    return $httpParamSerializer(options);
  };

  vm.toggleInlineFilter = () => {
    vm.gridOptions.enableFiltering = !vm.gridOptions.enableFiltering;
    vm.gridApi.core.notifyDataChange(uiGridConstants.dataChange.COLUMN);
  };

  startup();
}
