# cometa-lm-contract
Implementation of [Synthetix staking contract](https://solidity-by-example.org/defi/staking-rewards/) in Reach with some additional features, such as:
* Locks
* Flat fee to prevent spam
* Double rewards (in native and non-native token)
* Fee in %

Full automatic verification of the contract is infeasible due to complicated calculation results stored in `map`, however we added `check`s and `invariant`s where possible.

This contract is one of 2 contracts used in v0 of [Cometa](https://cometa.farm). Another contract is distribution contract which is almost the same as this one (the only difference is `stakeToken` used for rewards as well and there is no `rewarardToken`).
