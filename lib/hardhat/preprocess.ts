// don't check race conditions because this code is not intended to be run in parallel
/* eslint-disable require-atomic-updates */

import type {HardhatRuntimeEnvironment} from "hardhat/types";

import {exec} from "child_process";

import {checkDefined, checkState} from "../preconditions";

export const preprocessCode = (
  isLocalBuild: (hre: HardhatRuntimeEnvironment) => boolean,
): ((hre: HardhatRuntimeEnvironment) => Promise<
  | {
      transform: (line: string, sourceInfo: {absolutePath: string}) => string;
      settings: {strip: boolean};
    }
  | undefined
>) => {
  let inStrip = false;
  let absolutePath = "";
  let gitCommitHash: string | undefined;

  const preprocess = {
    transform: (line: string, sourceInfo: {absolutePath: string}): string => {
      if (absolutePath !== sourceInfo.absolutePath) {
        checkState(!inStrip, "Mismatched begin/end strip");
        absolutePath = sourceInfo.absolutePath;
      }
      const magicVal = "DEADBEEFCAFEBABEBEACBABEBA5EBA11B0A710ADB00BBABEDEFACA7EDEADFA11";
      if (line.includes(magicVal)) {
        line = line.replace(magicVal, checkDefined(gitCommitHash));
      }
      if (line.endsWith("// BEGIN STRIP")) {
        checkState(!inStrip, "BEGIN STRIP found when already stripping");
        inStrip = true;
      } else if (line.endsWith("// END STRIP")) {
        checkState(inStrip, "END STRIP found when not stripping");
        inStrip = false;
        return ""; // strip this line as well
      }
      if (!inStrip) {
        // make sure no console.log remains
        checkState(
          !line.includes("console.log"),
          `Forgot to strip a console.log statement in file ${absolutePath}`,
        );
      }
      return inStrip ? "" : line;
    },
    settings: {strip: true},
  };

  return async (hre: HardhatRuntimeEnvironment) => {
    if (isLocalBuild(hre)) return undefined;
    // we are building for deployment on external chains so we like
    // to include the correct git hashes into the contracts.

    const must_be_clean = false;
    // Make sure the repo is clean
    if (
      must_be_clean &&
      (await new Promise((resolve, reject) => {
        exec("git status --porcelain", (error, stdout) => {
          if (error) reject(error);
          resolve(stdout);
        });
      })) !== ""
    ) {
      throw new Error("Repo not clean");
    }
    // make sure the repo is on master
    if (
      must_be_clean &&
      (await new Promise((resolve, reject) => {
        exec("git rev-parse --abbrev-ref HEAD", (error, stdout) => {
          if (error) reject(error);
          resolve(stdout);
        });
      })) !== "master\n"
    ) {
      throw new Error("Not on master");
    }
    // make sure the repo is pushed on GitHub
    if (
      must_be_clean &&
      (await new Promise((resolve, reject) => {
        exec(
          "git fetch origin master > /dev/null && git log origin/master..master",
          (error, stdout) => {
            if (error) reject(error);
            resolve(stdout);
          },
        );
      })) !== ""
    ) {
      throw new Error("Master branch not pushed to github");
    }

    // todo make sure for prod builds we build from clean master
    gitCommitHash ??= await new Promise<string>((resolve, reject) => {
      exec('git log -1 --format=format:"%H"', (error, stdout) => {
        if (error) reject(error);
        resolve(`000000000000000000000000000000000000000000000000${stdout}`);
      });
    });

    return preprocess;
  };
};
