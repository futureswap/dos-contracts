// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../LiquidationStrategyV1.sol";

/**
 * @dev A special value used by a number of functions in the `IDosPortfolioApiV1` interface.
 *
 * Move into the interface when
 *
 *   https://github.com/ethereum/solidity/issues/8775
 *
 * is resolved.
 */
uint256 constant IDosPortfolioApiV1_MAX_AMOUNT = type(uint256).max;

/**
 * @title Portfolio operations in DOS.
 *
 * @notice Every portfolio, contract or EOA, is represented as an address holding assets.
 * Operations in this API are available to portfolios.
 */
interface IDosPortfolioApiV1 {
    /**
     * @notice Generated every time and update to an asset balance of a portfolio happens.
     *
     * When generated during a `transfers()` call: `from` and `to`  are `msg.sender` and `to`
     * argument respectively.
     *
     * When generated during a `deposit()` call: `from` is `0x0` and `to` is `msg.sender`.
     *
     * When generated during a `withdraw()` call: `from` is `msg.sender` and `to` is `0x0`.
     *
     * TODO Alternatively, we can use this event:
     *
     * ```solidity
     * event BalanceUpdate(indexed address portfolio, indexed uint16 assetId, int256 amount);
     * ```
     *
     * For `transfers()` we would have two updates, while for `deposit()` and `withdraw()` we would
     * have only one.  It could complicate asset movement tracking, as connection between `from` and
     * `to` is lost.  But as both events would be in the same transaction, it could be OK.
     */
    event Transfer(
        address indexed from,
        AssetId indexed assetId,
        address indexed to,
        uint256 amount
    );

    /**
     * @notice Transfers the specified amount of an ERC20 token between portfolios.  Sender is the
     * caller of the method.  Checks that the sender is liquid after the balance change.
     *
     * Allows transfers of assets and amounts in excess of the current balance of the sender,
     * creating debt on the sender balance.  Allowed, as long as the sender is still liquid after
     * the transfer.
     *
     * When called as part of an `batch()` call, liquidity check is deferred until the end of the
     * whole batch.
     *
     * See `transferNft()` for an NFT version of this operation.
     *
     * @param assetId Index of an ERC20 asset, can be retrieved from the asset registry.
     *      TODO Update when the asset registry API is implemented.
     *
     * @param to Receiver of the assets.  This address balance will be increased.
     *
     * @param amount Amount of the token to transfer, in the same decimal precision as the token
     *      itself.
     *
     *      `IDosPortfolioApiV1_MAX_AMOUNT` is allowed, and will cause `transfer()` to move all the
     *      positive asset of type `assetId` to be moved into the ownership of `to`.  If `to`
     *      balance of `assetId` is zero or is negative, than `IDosPortfolioApiV1_MAX_AMOUNT` is the
     *      same as specifying `0` - does not cause anything to be transferred.
     */
    function transfer(AssetId assetId, address to, uint256 amount) external;

    /**
     * @notice Transfers the specified amount of an ERC20 token from the ownership of the caller
     * into the ownership of DOS, increasing the portfolio balance accordingly.  Corresponding
     * amount need to be `approved()`, as this method will call `transferFrom(msg.sender)`.
     *
     * Use `withdraw()` for the reverse operation.
     *
     * See `depositNft()` for an NFT version of this operation.
     *
     * @param assetId Index of an ERC20 asset, can be retrieved from the asset registry.
     *      TODO Update when the asset registry API is implemented.
     *
     * @param amount Amount of the token to deposit, in the same decimal precision as the token
     *      itself.  This amount is added to the portfolio balance.
     *
     *      It can be lent to other portfolios, and might be temporarily inaccessible, while used by
     *      other portfolios.
     *
     *      Any borrows are still overcapitalized, so the value of the deposited assets is never
     *      lost.
     *
     *      This amount generates yield based on the current yield rate for the asset.
     *
     *      `IDosPortfolioApiV1_MAX_AMOUNT` is allowed, and will cause `deposit()` to call
     *      `balanceOf()` on the portfolio address to determine the total amount.
     */
    function deposit(AssetId assetId, uint256 amount) external;

    /**
     * @notice Transfers the specified amount of an ERC20 token from the ownership of DOS into the
     * ownership of the portfolio.  Corresponding amount is subtracted form the portfolio balance.
     * Checks that the portfolio is liquid after the balance update.
     *
     * Allows transfers of assets and amounts in excess of what is currently owned by the portfolio,
     * creating debt, as long as the portfolio is liquid after the transfer.
     *
     * As a subsequent operation, portfolio owner can perform an `ERC20.transfer()` to move the
     * assets further.
     *
     * When be called as part of an `batch()` call, liquidity check is deferred until the end
     * of the whole batch.
     *
     * Use `deposit()` for a reverse operation.
     *
     * See `withdrawNft()` for an NFT version of this operation.
     *
     * @param assetId Index of an ERC20 asset, can be retrieved from the asset registry.
     *      TODO Update when the asset registry API is implemented.
     *
     * @param amount Amount of the token to withdraw, in the same decimal precision as the token
     *      itself.  This amount is subtracted from the portfolio balance.
     *
     *      `IDosPortfolioApiV1_MAX_AMOUNT` is allowed, and will move maximum amount available on
     *      the portfolio balance, making it equal `0` for this asset.  This would not cause any
     *      debt to be allocated.
     *
     *      TODO What is the meaning of `IDosPortfolioApiV1_MAX_AMOUNT` for assets that are
     *      borrowed?  Would it cause a revert or be a noop?
     */
    function withdraw(AssetId assetId, uint256 amount) external;

    /**
     * @notice Returns balance of the specified portfolio, for the given asset.
     *
     * @return amount For NFT20 tokens, returns the balance.  Negative balance means that the caller
     *      portfolio has debt on this token.
     *      For ERC721 tokens, returns the total number of NFTs that portfolio holds.  It can not be
     *      negative.
     */
    function balanceOf(AssetId assetId, address portfolio) external view returns (int256 amount);

    /**
     * @notice Emitted by the `setLendingElection()` call.
     */
    event LendingElection(address indexed portfolio, uint16 indexed AssetId, uint256 amount);

    /**
     * @notice Changes which part of the asset owned by the portfolio can be lent out.
     *
     *      Amount that is lent generates yield, but may become inaccessible if borrowed by other
     *      portfolios, and DOS does not have any of this asset available at the moment.
     *
     *      Amount that is not lent does not generate yield, but is available for withdrawal, as
     *      long as the portfolio is liquid.
     *
     *      All portfolio assets are used as a collateral and might be taken over in case of a
     *      liquidation.
     *
     *      Note that NTFs can not be borrowed, and thus can not have any lending election set for
     *      them.
     *
     *      TODO Is it allowed to specify `noLendAmount` in excess of the current portfolio balance?
     *      What does it mean?
     *
     *      If we allow `noLendAmount` to exceed current balance, what happens when the asset is
     *      added?
     *
     *      What happens when we remove asset from this portfolio?  Do we also reduce `noLendAmount`
     *      associated with it?
     *
     *      Do we support `IDosPortfolioApiV1_MAX_AMOUNT`?  It could be supported even if we do not
     *      allow to specify `noLendAmount` in excess of the current amount, as a special case that
     *      means "never lend this asset".
     *
     *      TODO Not sure we will be able to provide a good implementation for this API.
     *
     * @param assetId Index of an ERC20 asset, can be retrieved from the asset registry.
     *      TODO Update when the asset registry API is implemented.
     *
     * @param noLendAmount Amount that is blocked from lending for this asset for this portfolio.
     *
     *      `IDosPortfolioApiV1_MAX_AMOUNT` means that this asset is never lent from this portfolio.
     */
    function setLendingElection(AssetId assetId, uint256 noLendAmount) external;

    /**
     * @notice Returns the current lending limit election for the calling portfolio for the selected
     * asset.  See `setLendingElection()` for details.
     */
    function getLendingElection(AssetId assetId) external view returns (uint256 noLendAmount);

    /**
     * @notice Emitted by the `setLiquidationStrategy()` call.
     */
    event SetLiquidationStrategyV1(address indexed portfolio, LiquidationStrategyV1 strategy);

    /**
     * @notice Selects a liquidation strategy for a portfolio.
     *
     * In order to borrow any asset, a portfolio has to have a liquidation strategy that specifies
     * how collateral is used to pay for the borrowed assets.
     *
     * See `../LiquidationStrategy.sol` for the details on how liquidation strategies are encoded,
     * and/or executed.
     */
    function setLiquidationStrategy(LiquidationStrategyV1 calldata strategy) external;

    /**
     * @notice Returns the current liquidation strategy for the caller portfolio.
     *
     * See `setLiquidationStrategy()` for details.
     */
    function getLiquidationStrategy() external view returns (LiquidationStrategyV1 memory strategy);

    /**
     * @notice Checks if the specified portfolio is liquid, based on the portfolio strategy.
     *
     * NOTE In order to be a `view` function, this function does not run a yield/fee update.
     * It means that the portfolio state might be different from what the function returns.  For
     * example, if nobody ran funding calculations for the assets this portfolio is holding, it
     * might be illiquid, due to borrow fees, while this function still says it is.
     *
     * Hopefully, in practice this should not happen to frequently.
     *
     * TODO Add an `isLiquidWithFunding()` function that runs funding computation as well, making
     * sure that returned value is more accurate.  It would only be useful for bots that use static
     * calls, as otherwise they would be paying for the funding state update.
     */
    function isLiquid(address portfolio) external view returns (bool);

    /**
     * @notice Emitted by a successful `liquidate()` call.
     *
     * TODO We should include additional events that would describe all the actual operations
     * generated from the liquidation strategy execution.
     */
    event Liquidated(address indexed portfolio);

    /**
     * @notice Attempts to liquidate a portfolio, if it is not liquid.
     *
     * It will call `isLiquid()` internally and will revert if the portfolio is currently liquid.
     *
     * This function will compute the funding update before checking portfolio liquidity or actually
     * running the liquidation strategy.
     */
    function liquidate(address portfolio) external;

    /**
     * @notice Shows how the selected liquidation strategy applies to the current portfolio assets.
     *
     * As the liquidation strategy can interact with the portfolio balances in a non-intuitive
     * manner, it makes sense for the UIs to be able to to show the details of this interaction.
     *
     * While the UI can retrieve the current strategy using the `getLiquidationStrategy()` call and
     * then simulate the risk calculation by calling all the corresponding asset risk evaluation
     * functions, it is a non-trivial process.  And as DOS already has code that have to perform
     * this computation, and is the ultimate source of truth for it, it makes sense to provide a
     * function that can do all this computation within DOS.  It could also save a lot of RPC calls
     * to the RPC provider for the UI.
     *
     * Ultimately, implementation of this function might be a duplicate effort, compared to the
     * liquidity checks, as those checks do not need to store intermediate results.  This is OK, as
     * it is still better to duplicate it in the contract code, rather then in the UI.  As this
     * function is expected to be used by UIs via an RPC call, rather than by other contracts, it
     * is more focused on the API UX, rather than on gas usage optimization.
     *
     * TODO Describe the return value.  Better use structs, and standard Solidity ABI encoding, in
     * order to make interaction on the UI side easier.
     *
     * Resulting value could both encode the strategy and record risk adjusted values of the
     * corresponding assets as they are used in the liquidation process.  This should allow the UI
     * to show a very meaningful explanation as to the state of the collateral and debt in the given
     * portfolio.
     */
    function getLiquidityTrace() external view returns (bytes memory todo);
}
