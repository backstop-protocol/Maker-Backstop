# 1. Introduction (Summary)

**Summary:** The `BAMMJoin` let peope deposit DAI (`vat.dai`) that is used to backstop a dedicated collateral Vault (e.g., WBTC-B).
Upon aliquidation in MakerDAO, the `dog` will call a new clipper implementation, namely `blipper`, who will first try to execute the liquidation by using the `BAMMJoin` deposits, according to a price that is taken from a real time price oracle, and a fixed discount.
If it fails, it reverts to the standard MakerDAO auction process.

User deposits are kept in the `pot` and withdraw only to facilitate liquidaitons. Whenever the `BAMMJoin` has non zero `gem` balance, it is offered for sale in return to DAI.
This is done by a speial formula that takes into account the inventory imbalance (DAI vs Gem balance) and the market price (taken from a real time price feed).

# 2. Considerations:
1. If WBTC-B is the collateral type, and the liquidation ratio is set to 130%, then MakerDAO can still relies on its current WBTC-A liquidators community in case the `BAMMJoin` inventory gets depleted. So as long as the debt ceiling remains low, the risk is very minimal.
2. During the liquidation, if the price feed value shows that the user collateral is not suffice to cover his debt, then the standard MakerDAO auction process is triggered. This mitigates attacks on the price oracle.
3. A sanity price for the price feed is needed in the rebalance process, this is TBD.
4. It is planned to have an additional incentive layer which will incentives longer deposit periods. Potentially by providing B.Protocol token incentives. All the upgradability mechanisim will be implemented there.
5. Currently the implementation supports only a single `ilk` type. In the future it would make sense to use the same dai to backstop multiple collaterals.
6. Currently user funds are kept in the DSR. In the future it would make sense to put it in places that offer higher yield, e.g., YFI or Compound.

