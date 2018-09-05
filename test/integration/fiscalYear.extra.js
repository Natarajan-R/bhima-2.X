/* global expect, agent */

const helpers = require('./helpers');

describe('(/fiscal) Fiscal Year extra operations', () => {
  const url = '/fiscal';
  const date = new Date('2017-08-24');

  const fiscalYear2015 = {
    id : 1,
    enterprise_id : 1,
    label : 'Test Fiscal Year 2015',
  };

  const fiscalYear2017 = {
    id : 3,
    enterprise_id : 1,
    label : 'Test Fiscal Year 2017',
  };

  const fiscalYear2017MonthsNumber = 12;

  const accounts = [
    { id : 81, debit : 77, credit : 0 },
    { id : 83, debit : 0, credit : 77 },
    { id : 174, debit : 23, credit : 0 },
    { id : 190, debit : 0, credit : 23 },
  ];

  const openingBalance = {};

  /**
   * this test is supposed to returns the fiscal year 2017
   * from the date 2017-08-24
   */
  it(`GET /fiscal/date?date=${flatDate(date)} returns the fiscal year from a given date`, () => {
    return agent.get(url.concat(`/date?date=${date}`))
      .then(res => {
        helpers.api.listed(res, 1);
        const [fy] = res.body;
        expect(fy).to.be.an('object');
        expect(fy).to.have.property('fiscal_year_id', 3);
        expect(fy).to.have.property('previous_fiscal_year_id', 2);
        expect(fy).to.have.property('label', 'Test Fiscal Year 2017');

        /**
         * dates are returned with timezone information
         * we extract just the date information
         * FIXME: timezone issue : we have 2017-12-31 in the database
         * but we get 2018-01-01, it is now difficult to test date.
         */
        expect(fy).to.have.property('start_date');
        expect(fy).to.have.property('end_date');
        const fyStartDate = flatDate(fy.start_date);
        const fyEndDate = flatDate(fy.end_date);
        expect(fyStartDate).to.be.equal('2017-01-01');
        expect(fyEndDate).to.be.equal('2017-12-31');

        /**
         * the percentage is value of consumed period in the fiscal year
         * until to the given date
         * proportion = (currentDate - startDate) / (nbMonthOfYear * 30.5)
         * proportion = ('2017-08-24' - '2017-01-01') / (12 * 30.5)
         * proportion = 235 / 366 = 0.6421 = 64.21%
         */
        expect(fy).to.have.property('percentage', 0.6421);
      })
      .catch(helpers.handler);
  });

  it('POST /fiscal/:id/opening_balance forbid to set the opening balance of a fiscal year which is not the first', () => {
    // define a not first fiscal year information
    openingBalance.id = fiscalYear2017.id;
    openingBalance.fiscal = fiscalYear2017;
    openingBalance.accounts = accounts;

    return agent.post(url.concat(`/${fiscalYear2017.id}/opening_balance`))
      .send({ params : openingBalance })
      .then(res => {
        helpers.api.errored(res, 400, 'ERRORS.NOT_BEGINING_FISCAL_YEAR');
      })
      .catch(helpers.handler);
  });

  it('POST /fiscal/:id/opening_balance set the opening balance of a fiscal year', () => {
    // define a not first fiscal year information
    openingBalance.id = fiscalYear2015.id;
    openingBalance.fiscal = fiscalYear2015;
    openingBalance.accounts = accounts;

    return agent.post(url.concat(`/${fiscalYear2015.id}/opening_balance`))
      .send({ params : openingBalance })
      .then(res => {
        expect(res).to.have.status(201);
      })
      .catch(helpers.handler);
  });

  it('GET /fiscal/:id/opening_balance returns the opening balance of a given fiscal year', () => {
    return agent.get(url.concat(`/${fiscalYear2015.id}/opening_balance`))
      .then(res => {
        const updatedAccounts = res.body.filter(item => {
          return [81, 83, 174, 190].indexOf(item.id) > -1;
        });
        const [first, second, third, fourth] = updatedAccounts;
        expect(first.balance).to.be.equal(77);
        expect(second.balance).to.be.equal(-77);
        expect(third.balance).to.be.equal(23);
        expect(fourth.balance).to.be.equal(-23);
      })
      .catch(helpers.handler);
  });

  it('GET /fiscal/:id/periods returns periods of the given fiscal year', () => {
    return agent.get(url.concat(`/${fiscalYear2017.id}/periods`))
      .then(res => {
        expect(res.body).to.have.length(fiscalYear2017MonthsNumber + 1);
        for (let i = 0; i < res.body.length; i++) {
          expect(res.body[i].number).to.be.equal(i);
        }
        const jan = res.body[1];
        const dec = res.body[12];
        expect(flatDate(jan.start_date)).to.be.equal('2017-01-01');
        expect(flatDate(jan.end_date)).to.be.equal('2017-01-31');
        expect(flatDate(dec.start_date)).to.be.equal('2017-12-01');
        expect(flatDate(dec.end_date)).to.be.equal('2017-12-31');
      })
      .catch(helpers.handler);
  });

  function flatDate(_date_) {
    const givenDate = new Date(_date_);
    const y = date.getFullYear();
    const m = numberWithZero(givenDate.getMonth() + 1);
    const d = numberWithZero(givenDate.getDate());
    const output = String(y).concat('-', m, '-', d);
    return output;
  }

  function numberWithZero(number) {
    return number < 10 ? '0'.concat(number) : number;
  }

});
