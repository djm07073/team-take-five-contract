function getPriceX96FromTick(tick: bigint) {
  if (tick >= 0) {
    return (10001n ** (2n * tick) * 2n ** 96n) / 10000n ** (2n * tick);
  } else {
    return (10000n ** (2n * -tick) * 2n ** 96n) / 10001n ** (2n * -tick);
  }
}

function getTickFromPriceX96(price: bigint) {}

function getDepositRatio(price: bigint, tickLower: bigint, tickUpper: bigint) {
  const upper = getPriceX96FromTick(tickUpper);
  const lower = getPriceX96FromTick(tickLower);
  return (price * upper * (price - lower)) / ((upper - price) * 2n ** 192n);
}
export { getPriceX96FromTick, getTickFromPriceX96, getDepositRatio };
