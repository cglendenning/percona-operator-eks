/** Pure helpers for restore logic; kept separate so unit tests do not load @kubernetes/client-node. */

export function parseS3Bucket(destination: string): string {
  const match = destination.match(/^s3:\/\/([^/]+)/);
  if (!match) {
    throw new Error(`Cannot parse S3 bucket from destination: ${destination}`);
  }
  return match[1]!;
}

export function matchesRunningRestoreState(state: string | undefined): boolean {
  return state === "Starting" || state === "Running";
}
