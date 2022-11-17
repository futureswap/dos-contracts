// These methods are modelled after Guavas Preconditions class
// see https://guava.dev/releases/19.0/api/docs/com/google/common/base/Preconditions.html
export function checkDefined<T>(
  val: T | null | undefined,
  message = "Should be defined"
): T {
  if (val === null || val === undefined) {
    throw new Error(message);
  }
  return val;
}

export function checkArgument(expression: boolean, message = "checkArgument") {
  if (!expression) {
    throw new Error(message);
  }
}

export function checkState(expression: boolean, message = "checkState") {
  if (!expression) {
    throw new Error(message);
  }
}
