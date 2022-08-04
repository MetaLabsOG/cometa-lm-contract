"reach 0.1";
"use strict";

// 1e18, approximately 2^60
const BIG_NUMBER = UInt256(1_000_000_000_000_000_000);
const SHORTEST_POSSIBLE_FARM_BLOCKS = 100_000; // 3-5 days
const LONGEST_POSSIBLE_FARM_BLOCKS = 10_000_000; // 1-1.5 years
const MAX_FLAT_ALGO_CREATION_FEE = 1_000_000_000; // 1000 ALGO

// Defines the least non-zero fee percentage (fee = 1 is 0.01%, fee = FEE_RATIO is 100%).
const FEE_RATIO = 10000;

// We have one "virtual" token always staked to avoid potential
// * division by zero
// * rewards emission loss
const VIRTUAL_STAKE = 1;

// We return current round from every API call to enable testing
const TimedResult = (T) =>
  Struct([
    ["now", UInt],
    ["result", T],
  ]);

// Initial state of one particular farm.
// Values are provided initially by the Creator participant and later accessible in "State" view.
const InitialStateObj = {
  // Account which gets the farm creation fees. It is always Cometa's wallet.
  // Unfortunately, it cannot be hardcoded, so it shall be checked on the backend.
  beneficiary: Address,
  // Creation fee (in 0.01%, charged from reward tokens).
  creationFee: UInt,
  // An additional flat creation fee to prevent spam.
  flatAlgoCreationFee: UInt,
  // Token to stake in this farm. Usually LP token but can be anything.
  stakeToken: Token,
  // Token which farm users will get as reward.
  rewardToken: Token,
  // First block when the farm starts providing rewards.
  beginBlock: UInt,
  // Last possible block when the farm will cease to provide rewards.
  endBlock: UInt,
  // *rewardToken* distributed per block.
  rewardPerBlock: UInt,
  // ALGO distributed per block. Usually used for Algorand Foundation's incetives.
  extraAlgoRewardPerBlock: UInt,
  // Length of lock in seconds. If it is 0, there is no lock.
  lockLengthBlocks: UInt,
};

const InitialState = Struct([
  ["beneficiary", Address],
  ["creationFee", UInt],
  ["flatAlgoCreationFee", UInt],
  ["stakeToken", Token],
  ["rewardToken", Token],
  ["beginBlock", UInt],
  ["endBlock", UInt],
  ["rewardPerBlock", UInt],
  ["extraAlgoRewardPerBlock", UInt],
  ["lockLengthBlocks", UInt],
]);

const GlobalState = Struct([
  // initially set to 0
  ["totalStaked", UInt],
  ["lastUpdateBlock", UInt],
  ["rewardPerTokenStored", UInt256],
]);

const LocalState = Struct([
  ["staked", UInt],
  ["reward", UInt],
  // Can be reset by user (via ClearTransaction).
  // Still safe because everything else will be reset too.
  ["lockTimestamp", UInt],
  ["rewardPerTokenPaid", UInt256],
]);

export const main = Reach.App(() => {
  setOptions({
    untrustworthyMaps: true,
    verifyPerConnector: true,
    connectors: [ALGO],
    // Full verification is infeasible here but we do limited verification with *check*.
    verifyArithmetic: false,
  });

  const Common = {
    deployed: Fun([], Null),
  };

  const Creator = Participant("Creator", {
    ...Common,
    getParams: Fun(
      [],
      Object({
        ...InitialStateObj,
      })
    ),
  });

  // Dummy Participant. We need it for more convenient testing.
  const User = Participant("User", {
    ...Common,
  });

  // Does nothing, allows "Dummy" participants to compile in strict mode.
  void User;

  // Standard view structure of MetaLabs contracts.
  const State = View({
    initial: InitialState,
    global: GlobalState,
    local: Fun([Address], LocalState),
  });

  const Api = API({
    stake: Fun([UInt], TimedResult(UInt)),
    unstake: Fun([UInt], TimedResult(UInt)),
    claim: Fun([], TimedResult(Tuple(UInt, UInt))),

    // Only for beneficiary
    // Returns (rewardTokenFees, algoFees)
    claimFees: Fun([], TimedResult(Tuple(UInt, UInt))),
  });

  const initialChecks = (
    creationFee,
    flatAlgoCreationFee,
    stakeToken,
    rewardToken,
    beginBlock,
    endBlock,
    rewardPerBlock,
    extraAlgoRewardPerBlock,
    lockLengthBlocks
  ) => {
    check(
      stakeToken != rewardToken,
      "Reach requires all tokens to be different. Consider using distribution contract instead."
    );

    check(creationFee * 5 <= FEE_RATIO, "Maximum possible creation fee is 20%");

    check(
      flatAlgoCreationFee <= MAX_FLAT_ALGO_CREATION_FEE,
      "Flat ALGO creation fee cannot be more than 1000 ALGO"
    );

    check(beginBlock < endBlock);
    // TODO: uncomment before deploy: check(beginBlock + SHORTEST_POSSIBLE_FARM_BLOCKS <= endBlock);
    check(endBlock - beginBlock < LONGEST_POSSIBLE_FARM_BLOCKS);
    check(lockLengthBlocks < LONGEST_POSSIBLE_FARM_BLOCKS);
    // Locks are automatically lifted at endBlock, so larger *lockLenghtBlocks* do not make sense.
    check(lockLengthBlocks <= endBlock - beginBlock);

    // If `rewardPerBlock == 0`, then `totalRewardAmount == 0` and we have div by zero in `getAlgoReward`.
    // So we cannot have zero reward per block without fully duplicating the reward logic for ALGO rewards.
    check(rewardPerBlock > 0);
    check(rewardPerBlock < UInt.max - MAX_FLAT_ALGO_CREATION_FEE);
    check(extraAlgoRewardPerBlock < UInt.max - MAX_FLAT_ALGO_CREATION_FEE);
    check(flatAlgoCreationFee <= MAX_FLAT_ALGO_CREATION_FEE);

    // overflow assumes
    // 1. This avoids any overflow problems with totalRewards/creationFee calculation. However, this adds an upper bound
    // on rewardPerBlock which is not necessary to be that small. It is __for sure__ still big enough for any
    // farm with any token with a sane number of decimals, but who knows...
    check(rewardPerBlock < UInt.max / ((endBlock - beginBlock) * FEE_RATIO));
    check(
      extraAlgoRewardPerBlock + flatAlgoCreationFee <
        UInt.max / ((endBlock - beginBlock) * FEE_RATIO)
    );
  };

  init();

  Creator.only(() => {
    const {
      beneficiary,
      creationFee,
      flatAlgoCreationFee,
      stakeToken,
      rewardToken,
      beginBlock,
      endBlock,
      rewardPerBlock,
      extraAlgoRewardPerBlock,
      lockLengthBlocks,
    } = declassify(interact.getParams());

    initialChecks(
      creationFee,
      flatAlgoCreationFee,
      stakeToken,
      rewardToken,
      beginBlock,
      endBlock,
      rewardPerBlock,
      extraAlgoRewardPerBlock,
      lockLengthBlocks
    );
  });

  Creator.publish(
    beneficiary,
    creationFee,
    flatAlgoCreationFee,
    stakeToken,
    rewardToken,
    beginBlock,
    endBlock,
    rewardPerBlock,
    extraAlgoRewardPerBlock,
    lockLengthBlocks
  );

  initialChecks(
    creationFee,
    flatAlgoCreationFee,
    stakeToken,
    rewardToken,
    beginBlock,
    endBlock,
    rewardPerBlock,
    extraAlgoRewardPerBlock,
    lockLengthBlocks
  );

  const totalRewardAmount = (endBlock - beginBlock) * rewardPerBlock;
  const totalAlgoRewardAmount = (endBlock - beginBlock) * extraAlgoRewardPerBlock;

  const creationFeeToPay = (totalRewardAmount * creationFee) / FEE_RATIO;
  const creationAlgoFeeToPay = (totalAlgoRewardAmount * creationFee) / FEE_RATIO;

  commit();
  // Can't pay non-native token in the first transaction (RE0102), therefore it is separate from publish.
  Creator.pay([
    totalAlgoRewardAmount + creationAlgoFeeToPay + flatAlgoCreationFee,
    [totalRewardAmount + creationFeeToPay, rewardToken],
  ]);

  // Amount of staked *stakeToken* for each Creator participant.
  const stakedM = new Map(UInt);
  const staked = (p) => fromSome(stakedM[p], 0);
  stakedM[Creator] = VIRTUAL_STAKE;
  // Amount of *rewardToken* farmed but not claimed for each Creator participant.
  const rewardM = new Map(UInt);
  const reward = (p) => fromSome(rewardM[p], 0);
  // Last block when some action which caused staked to become non-zero happened.
  const lockFromBlockM = new Map(UInt);
  const lockFromBlock = (p) => fromSome(lockFromBlockM[p], 0);
  // Already claimed rewards per token. Similar to synthetix rewards: https://solidity-by-example.org/defi/staking-rewards/
  const rewardPerTokenPaidM = new Map(UInt256);
  const rewardPerTokenPaid = (p) => fromSome(rewardPerTokenPaidM[p], UInt256(0));

  each([Creator, User], () => {
    interact.deployed();
  });

  State.initial.set(
    InitialState.fromObject({
      beneficiary,
      creationFee,
      flatAlgoCreationFee,
      stakeToken,
      rewardToken,
      beginBlock,
      endBlock,
      rewardPerBlock,
      extraAlgoRewardPerBlock,
      lockLengthBlocks,
    })
  );

  State.local.set((addr) => {
    return LocalState.fromObject({
      staked: staked(addr),
      reward: reward(addr),
      lockTimestamp: lockFromBlock(addr),
      rewardPerTokenPaid: rewardPerTokenPaid(addr),
    });
  });

  const getAlgoReward = (n) => muldiv(n, totalAlgoRewardAmount, totalRewardAmount);

  const claimRewards = (p) => {
    const claimedReward = reward(p);
    const extraAlgoReward = getAlgoReward(claimedReward);

    rewardM[p] = 0;

    // Ugly and has downsides but we were unable to find a sane way to avoid it.
    enforce(claimedReward <= balance(rewardToken) && extraAlgoReward <= balance());
    transfer([extraAlgoReward, [claimedReward, rewardToken]]).to(p);

    return [claimedReward, extraAlgoReward];
  };

  const [totalStaked, lastUpdateBlock, rewardPerTokenStored, rewardTokenFees, algoFees] =
    parallelReduce([
      VIRTUAL_STAKE,
      beginBlock,
      UInt256(0),
      creationFeeToPay,
      creationAlgoFeeToPay + flatAlgoCreationFee,
    ])
      .define(() => {
        enforce(rewardTokenFees <= balance(rewardToken));
        enforce(algoFees <= balance());

        const nextBlock = () => {
          const now = thisConsensusTime();
          return now > lastUpdateBlock ? now : lastUpdateBlock;
        };

        const timed = (T, v) =>
          TimedResult(T).fromObject({
            now: nextBlock(),
            result: v,
          });

        const lastBlockWithRewards = () => {
          const next = nextBlock();
          return next < endBlock ? next : endBlock;
        };

        const isUnlocked = (p) => {
          const next = nextBlock();
          return next > endBlock || lockFromBlock(p) + lockLengthBlocks <= next;
        };

        const getNewRewardPerToken = () => {
          const rewardBlocksPassed = UInt256(lastBlockWithRewards() - lastUpdateBlock);
          const addedReward =
            (UInt256(rewardPerBlock) * rewardBlocksPassed * BIG_NUMBER) / UInt256(totalStaked);

          return rewardPerTokenStored + addedReward;
        };

        // This MUST be called every time when participant does any action. E.g. stake and unstake.
        // The reason is that we calculate amount to claim from the last known state (staked amount, time when staked, reward amount),
        // update state, give rewards, and pending rewards become zero until the next state update.
        const updateReward = (p) => {
          const rewardPerTokenStoredNew = getNewRewardPerToken();

          const rewardToPayNow =
            (UInt256(staked(p)) * (rewardPerTokenStoredNew - rewardPerTokenPaid(p))) / BIG_NUMBER;

          rewardM[p] = UInt(rewardToPayNow) + reward(p);
          rewardPerTokenPaidM[p] = rewardPerTokenStoredNew;

          return rewardPerTokenStoredNew;
        };

        const updateLock = (p) => {
          const next = nextBlock();
          lockFromBlockM[p] = next < endBlock ? next : endBlock;
        };

        State.global.set(
          GlobalState.fromObject({
            totalStaked,
            lastUpdateBlock,
            rewardPerTokenStored,
          })
        );
      })
      .invariant(staked(Creator) >= VIRTUAL_STAKE)
      .invariant(totalStaked == balance(stakeToken) + VIRTUAL_STAKE)
      .invariant(totalStaked < UInt.max)
      .invariant(
        lastBlockWithRewards() >= lastUpdateBlock &&
          lastUpdateBlock >= beginBlock &&
          lastBlockWithRewards() - lastUpdateBlock <= endBlock - beginBlock
      )
      // Even this invariant is not holding with untrustworthyMaps, even though it should (it actually holds
      // even with the assumption of random local state clearances, because it's the upper bound on each actual valu)
      // .invariant(stakedM.all((stake) => stake <= totalStaked))

      // Invariants regarding reward calculation are extremely hard to enforce
      // .invariant(rewardM.all((r) => r <= totalRewardAmount))
      // .invariant(
      //   rewardPerTokenStored <=
      //     UInt256((lastBlockWithRewards() - beginBlock) * rewardPerBlock) * BIG_NUMBER
      // )
      // // .invariant(lockFromBlockM.all((lock) => lock < BLOCK_NUMBER_WHICH_MAKES_SENSE))
      // .invariant(rewardPerTokenPaidM.all((paid) => paid <= rewardPerTokenStored))
      .while(true)
      .paySpec([stakeToken, rewardToken])
      .api_(Api.stake, (toStake) => {
        check(totalStaked + toStake < UInt.max, "maximum stakes has been reached");

        return [
          [0, [toStake, stakeToken], [0, rewardToken]],
          (callback) => {
            const newRewardPerTokenStored = updateReward(this);

            if (isUnlocked(this)) {
              void claimRewards(this);
            }

            stakedM[this] = staked(this) + toStake;

            updateLock(this);
            callback(timed(UInt, toStake));
            return [
              totalStaked + toStake,
              lastBlockWithRewards(),
              newRewardPerTokenStored,
              rewardTokenFees,
              algoFees,
            ];
          },
        ];
      })
      .api_(Api.unstake, (toUnstake) => {
        check(staked(this) <= balance(stakeToken));
        check(toUnstake < UInt.max, "tried to unstake too much really");
        check(
          toUnstake + (this === beneficiary ? VIRTUAL_STAKE : 0) <= staked(this),
          "tried to unstake more than staked on record"
        );

        return [
          [0, [0, stakeToken], [0, rewardToken]],
          (callback) => {
            const newRewardPerTokenStored = updateReward(this);
            const lostReward = isUnlocked(this) ? 0 : reward(this);
            const lostAlgoReward = getAlgoReward(lostReward);
            // Removing all rewards if unstaking before unlock, otherwise we can stake for a short time,
            // then unstake before lock and take rewards after unlock.
            if (!isUnlocked(this)) {
              rewardM[this] = 0;
            }
            void claimRewards(this);

            stakedM[this] = staked(this) - toUnstake;

            transfer([[toUnstake, stakeToken]]).to(this);

            updateLock(this);
            callback(timed(UInt, toUnstake));
            return [
              totalStaked - toUnstake,
              lastBlockWithRewards(),
              newRewardPerTokenStored,
              rewardTokenFees + lostReward,
              algoFees + lostAlgoReward,
            ];
          },
        ];
      })
      .api_(Api.claim, () => {
        return [
          [0, [0, stakeToken], [0, rewardToken]],
          (callback) => {
            const newRewardPerTokenStored = updateReward(this);
            const unlocked = isUnlocked(this);

            if (unlocked) {
              const [claimedReward, extraAlgoReward] = claimRewards(this);
              updateLock(this);
              callback(timed(Tuple(UInt, UInt), [claimedReward, extraAlgoReward]));
            } else {
              // do not update the lock: no action has been done in this case except
              // reward recalculation
              callback(timed(Tuple(UInt, UInt), [0, 0]));
            }

            return [
              totalStaked,
              lastBlockWithRewards(),
              newRewardPerTokenStored,
              rewardTokenFees,
              algoFees,
            ];
          },
        ];
      })
      .api_(Api.claimFees, () => {
        check(this === beneficiary, "only beneficiary can claim creation fees");

        return [
          [0, [0, stakeToken], [0, rewardToken]],
          (callback) => {
            transfer([algoFees, [rewardTokenFees, rewardToken]]).to(beneficiary);
            callback(timed(Tuple(UInt, UInt), [rewardTokenFees, algoFees]));
            return [totalStaked, lastUpdateBlock, rewardPerTokenStored, 0, 0];
          },
        ];
      });

  commit();
});
