// TODO Handle HTTP exception errors (displayed contextually on form)
angular.module('bhima.controllers')
.controller('EmployeeController', EmployeeController);

EmployeeController.$inject = [
  'EmployeeService', 'ServiceService', 'GradeService', 'FunctionService', 'util', 'EnterpriseService', 'FinancialService', '$translate', '$window', 'SessionService'
];

function EmployeeController(Employees, Services, Grades, Functions, util, Enterprises, FinancialService, $translate, $window, SessionService) {
  var vm = this;

  vm.enterprises = [];
  vm.choosen = {};
  vm.state = 'default';  
  vm.view = 'default';
  vm.projectId = SessionService.project.id;

  // bind methods
  vm.create = create;
  vm.update = update;
  vm.cancel = cancel;
  vm.submit = submit;
  vm.del    = del;
  vm.more   = more;

  // Define limits for DOB
  vm.minDOB = util.minDOB;
  vm.maxDOB = util.maxDOB;    

  function handler(error) {
    console.error(error);
    vm.state.error();
  }

  // sets the module view state
  function setState(state) {
    vm.state = state;
  }

  // fired on startup
  function startup() {
    // load Employees
    refreshEmployees();

    // load Services
    Services.read().then(function (data) {
      vm.services = data;
    }).catch(handler);

    // load Grades
    Grades.read(null, { detailed : 1 }).then(function (data) {
      data.forEach(function (g) {
        g.format = g.code + ' - ' + g.text;
      });
      vm.grades = data;
    }).catch(handler);

    // load Functions
    Functions.read().then(function (data) {
      vm.functions = data;
    }).catch(handler);

    // load Enterprises
    Enterprises.read().then(function (data) {
      vm.enterprises = data;
    }).catch(handler);

    // load Cost Center
    FinancialService.readCostCenter().then(function (data) {
      vm.costCenters = data;
    }).catch(handler);

    // load Profit Center
    FinancialService.readProfitCenter().then(function (data) {
      vm.profitCenters = data;
    }).catch(handler);

    setState('default');
  }

  function cancel() {
    setState('default');
    vm.view = 'default';
  }

  function create() {
    vm.view = 'create';
    vm.employee = {};
  }

  // switch to update mode
  // data is an object that contains all the information of a employee 
  function update(data) {
    setState('default');
    vm.employee= data;
    vm.view = 'update';
  }

  // switch to view more information about 
  // data is an object that contains all the information of a employee 
  function more(data) {
    setState('default');
    vm.employee= data;
    vm.choosen.employee = data.name;
    var ccId = data.cost_center_id;
    var pcId = data.profit_center_id;
    
    // load Cost Center value for a specific employee 
    FinancialService.getCost(vm.projectId,ccId).
    then(function (data) {
      vm.choosen.charge = data.cost;
    }).catch(handler);

    // load Profit Center value for a specific employee 
    FinancialService.getProfit(vm.projectId,pcId).
    then(function (data) {
      vm.choosen.profit = data.profit;
    }).catch(handler);

    vm.view = 'more';
  }

  // switch to delete warning mode
  function del(employee) {
    var bool = $window.confirm($translate.instant('PROJECT.CONFIRM'));

     // if the user clicked cancel, reset the view and return
     if (!bool) {
        vm.view = 'default';
        return;
     }

    // if we get there, the user wants to delete a employee
    vm.view = 'delete_confirm';
    Services.delete(employee.id)
    .then(function () {
       vm.view = 'delete_success';
       return refreshEmployees();
    })
    .catch(function (error) {
      vm.HTTPError = error;
      vm.view = 'delete_error';
    });
  }


  // refresh the displayed Services
  function refreshEmployees() {
    return Employees.read()
    .then(function (data) {
      vm.employees = data;
    });
  }

  // form submission
  function submit(invalid) {
    if (invalid) { return; }

    var promise;
    var creation = (vm.view === 'create');
    var employee = angular.copy(vm.employee);

    promise = (creation) ?
      Services.create(employee) :
      Services.update(employee.id, employee);

    promise
      .then(function (response) {
        return refreshServices();
      })
      .then(function () {
        update(employee.id);
        vm.view = creation ? 'create_success' : 'update_success';
      })      
      .catch(handler);
  }

  startup();
}
