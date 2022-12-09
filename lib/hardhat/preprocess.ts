// don't check race conditions because this code is not intended to be run in parallel
/* eslint-disable require-atomic-updates */

import type {HardhatRuntimeEnvironment} from "hardhat/types";

import {promisify} from "node:util";
import {exec as execCallback} from "node:child_process";

import {checkDefined, checkState} from "../preconditions";

const exec = promisify(execCallback);

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
    // we are building for deployment on external chains, so we like
    // to include the correct git hashes into the contracts.

    // make sure the repo is clean
    const {stdout: gitStatusPorcelain} = await exec("git status --porcelain");
    if (gitStatusPorcelain) throw new Error("Repo not clean");

    // make sure the repo is on master
    const {stdout: gitBranch} = await exec("git rev-parse --abbrev-ref HEAD");
    if (gitBranch !== "master\n") throw new Error("Not on master");

    // make sure the repo is pushed on GitHub
    const {stdout: gitDiffWithRemote} = await exec(
      "git fetch origin master > /dev/null && git log origin/master..master",
    );
    if (gitDiffWithRemote) throw new Error("Master branch not pushed to github");

    // todo make sure for prod builds we build from clean master
    const {stdout: gitCommitHashRaw} = await exec('git log -1 --format=format:"%H"');
    gitCommitHash ??= `000000000000000000000000000000000000000000000000${gitCommitHashRaw}`;

    return preprocess;
  };
};
