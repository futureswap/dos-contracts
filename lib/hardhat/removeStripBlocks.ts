import { HardhatRuntimeEnvironment } from "hardhat/types";
import { checkDefined, checkState } from "../../lib/preconditions";
import { exec } from "child_process";

export const createStripFn = (
  shouldStripFn: (hre: HardhatRuntimeEnvironment) => boolean
) => {
  let inStrip = false;
  let absolutePath = "";
  let gitCommitHash: string | undefined = undefined;

  const preprocess = {
    transform: (line: string, sourceInfo: { absolutePath: string }): string => {
      if (absolutePath !== sourceInfo.absolutePath) {
        checkState(!inStrip, "Mismatched begin/end strip");
        absolutePath = sourceInfo.absolutePath;
      }
      const magicVal =
        "DEADBEEFCAFEBABEBEACBABEBA5EBA11B0A710ADB00BBABEDEFACA7EDEADFA11";
      if (line.includes(magicVal)) {
        line = line.replace(magicVal, checkDefined(gitCommitHash));
      }
      if (line.endsWith("// BEGIN STRIP")) {
        checkState(!inStrip, "BEGIN STRIP found when already stripping");
        inStrip = true;
      } else if (line.endsWith("// END STRIP")) {
        checkState(inStrip, "END STRIP found when not stripping");
        inStrip = false;
        return ""; // Strip this line as well
      }
      if (!inStrip) {
        // Make sure no console.log remains
        checkState(
          line.indexOf("console.log") === -1,
          "Forgot to strip a console.log statement in file " + absolutePath
        );
      }
      return inStrip ? "" : line;
    },
    settings: { strip: true },
  };

  return async (hre: HardhatRuntimeEnvironment) => {
    if (!shouldStripFn(hre)) return undefined;
    if (gitCommitHash === undefined) {
      // TODO make sure for prod builds we build from clean master
      gitCommitHash = await new Promise((resolve, reject) => {
        exec('git log -1 --format=format:"%H"', (error, stdout, stderr) => {
          if (error) reject(error);
          resolve("000000000000000000000000000000000000000000000000" + stdout);
        });
      });
    }
    return preprocess;
  };
};
