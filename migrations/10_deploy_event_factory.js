const CategoricalEvent = artifacts.require('CategoricalEvent')
const ScalarEvent = artifacts.require('ScalarEvent')
const OutcomeToken = artifacts.require('OutcomeToken')
const EventFactory = artifacts.require('EventFactory')

module.exports = function (deployer) {
    deployer.deploy(EventFactory, CategoricalEvent.address, ScalarEvent.address, OutcomeToken.address)
}
