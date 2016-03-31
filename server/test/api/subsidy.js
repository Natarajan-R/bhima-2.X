/* jshint expr:true */
var chai = require('chai');
var expect = chai.expect;

var helpers = require('./helpers');
helpers.configure(chai);

describe('(/subsidies) The subsidy API', function () {
  var agent = chai.request.agent(helpers.baseUrl);

  var newSubsidy = {
    account_id:  3626,
    label:       'tested subsidy',
    description: 'This is for the test',
    value:       10
  };

  var wrongSubsidy = {
    account_id:  3626,
    label:       'tested wrong subsidy',
    description: 'This is for the wrong value test',
    value:       -10
  };

  var responseKeys = [
    'id', 'account_id', 'label', 'description', 'value', 'created_at', 'updated_at'
  ];

  // ensure the client is logged in before tests start
  before(helpers.login(agent));

  it('GET /subsidies returns an empty list of subsidies', function () {
      return agent.get('/subsidies')
        .then(function (res) {
          helpers.api.listed(res, 0);
        })
        .catch(helpers.handler);
    });

  it('POST /subsidies adds a subsidy', function () {
    return agent.post('/subsidies')
      .send(newSubsidy)
      .then(function (res) {
        helpers.api.created(res);
        newSubsidy.id = res.body.id;
        return agent.get('/subsidies/' + newSubsidy.id);
      })
      .then(function (res){
        expect(res).to.have.status(200);
        expect(res.body).to.have.all.keys(responseKeys);
      })
     .catch(helpers.handler);
  });

  it('POST /subsidies refuses to add a wrong subsidy', function () {
    return agent.post('/subsidies')
      .send(wrongSubsidy)
      .then(function (res) {
        helpers.api.errored(res, 400);
      })
      .catch(helpers.handler);
  });

  it('GET /subsidies returns an array of one subsidy', function () {
      return agent.get('/subsidies')
        .then(function (res) {
          helpers.api.listed(res, 1);
        })
        .catch(helpers.handler);
    });

  it('GET /subsidies/:id returns one subsidy', function () {
    return agent.get('/subsidies/'+ newSubsidy.id)
      .then(function (res) {
        expect(res).to.have.status(200);
        expect(res).to.be.json;
        expect(res.body).to.not.be.empty;
        expect(res.body.id).to.be.equal(newSubsidy.id);
        expect(res.body).to.have.all.keys(responseKeys);
      })
      .catch(helpers.handler);
  });

  it('PUT /subsidies/:id updates the newly added subsidy', function () {
    var updateInfo = { value : 50 };
    return agent.put('/subsidies/'+ newSubsidy.id)
      .send(updateInfo)
      .then(function (res) {
        expect(res).to.have.status(200);
        expect(res).to.be.json;
        expect(res.body.id).to.equal(newSubsidy.id);
        expect(res.body.value).to.equal(updateInfo.value);
      })
      .catch(helpers.handler);
  });

   it('DELETE /subsidies/:id deletes a subsidy', function () {
    return agent.delete('/subsidies/' + newSubsidy.id)
      .then(function (res) {

        // make sure the record is deleted
        helpers.api.deleted(res);

        // re-query the database
        return agent.get('/subsidies/' + newSubsidy.id);
      })
      .then(function (res) {
        helpers.api.errored(res, 404);
      })
      .catch(helpers.handler);
  });
});
