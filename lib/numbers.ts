import {BigNumber, utils} from "ethers";

export const toWei = (x: number | string | BigNumber | bigint, decimals = 18): bigint => {
  const type = typeof x;

  if (type === "bigint") {
    return (x as bigint) * 10n ** BigInt(decimals);
  }

  switch (type) {
    case "number": {
      const number = x as number;
      const fixed = number.toFixed(decimals);
      const index = fixed.indexOf(".");
      const s = fixed.substring(0, index) + fixed.substring(index + 1, fixed.length);
      return BigInt(s);
    }
    case "string":
      return BigInt(stringToWei(x as string, decimals));
    case "object":
      if (BigNumber.isBigNumber(x)) {
        return stringToWei(x.toString(), decimals);
      } else {
        throw Error(`invalid value: ${x}`);
      }
    default:
      throw Error(`invalid value: ${x}`);
  }
};

const USDC_DECIMALS = 6;

export const toWeiUsdc = (usdAmount: number): bigint => toWei(usdAmount, USDC_DECIMALS);

const stringToWei = (value: string, decimals = 18) => {
  const s = utils.parseUnits(value, decimals).toString();
  return BigInt(s);
};

export const isEqualWithinEps = (v: bigint, e: bigint, eps: number): boolean => {
  const delta = Number(v - e);
  const percent = Math.abs(delta / Number(e));
  return percent < eps;
};

export const numberToHexString = (n: number): string => {
  // eslint-disable-next-line @typescript-eslint/no-magic-numbers
  return `0x${n.toString(16)}`;
};
