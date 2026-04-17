import { ListObjectsV2Command, type ListObjectsV2CommandOutput, S3Client } from "@aws-sdk/client-s3";

export type S3ClientConfig = {
  endpoint: string;
  region: string;
  forcePathStyle: boolean;
  accessKeyId: string;
  secretAccessKey: string;
};

// Expected folder/prefix shape (as used by pxc-backup in this environment):
//   db-YYYY-MM-DD-HH:MM:SS-full/
// Full destination passed to Percona restore:
//   s3://<bucket>/db-YYYY-MM-DD-HH:MM:SS-full
/** Fixed layout only (no env-driven regex: avoids ReDoS / unexpected pattern injection). */
const BACKUP_FOLDER_RE = /^db-(\d{4})-(\d{2})-(\d{2})-(\d{2}):(\d{2}):(\d{2})-full\/?$/;

type BackupParts = { y: number; mo: number; d: number; h: number; mi: number; s: number };

function parseBackupParts(folderNameWithOptionalSlash: string): BackupParts {
  const m = folderNameWithOptionalSlash.match(BACKUP_FOLDER_RE);
  if (!m) {
    throw new Error(`Backup folder name does not match expected pattern: ${JSON.stringify(folderNameWithOptionalSlash)}`);
  }

  const y = Number(m[1]);
  const mo = Number(m[2]);
  const d = Number(m[3]);
  const h = Number(m[4]);
  const mi = Number(m[5]);
  const s = Number(m[6]);

  if (![y, mo, d, h, mi, s].every((n) => Number.isFinite(n))) {
    throw new Error(`Failed to parse backup timestamp tuple from folder: ${JSON.stringify(folderNameWithOptionalSlash)}`);
  }

  return { y, mo, d, h, mi, s };
}

function compareBackupFolders(a: string, b: string): number {
  const A = parseBackupParts(`${a}/`);
  const B = parseBackupParts(`${b}/`);

  const tupleCmp =
    A.y - B.y ||
    A.mo - B.mo ||
    A.d - B.d ||
    A.h - B.h ||
    A.mi - B.mi ||
    A.s - B.s;

  if (tupleCmp !== 0) return tupleCmp;
  // Deterministic tie-break (should be extremely rare)
  return a.localeCompare(b);
}

function normalizeFolderPrefix(p: string): string {
  return p.replace(/\/$/, "");
}

export async function findLatestBackupS3Destination(args: {
  cfg: S3ClientConfig;
  bucket: string;
  /**
   * Optional key prefix *within the bucket* (e.g. a parent directory if you ever shard backups).
   * Backup folders themselves still must match `db-YYYY-MM-DD-HH:MM:SS-full/`.
   */
  prefix?: string;
}): Promise<{ destination: string; chosenPrefix: string }> {
  const client = new S3Client({
    region: args.cfg.region,
    endpoint: args.cfg.endpoint,
    forcePathStyle: args.cfg.forcePathStyle,
    credentials: {
      accessKeyId: args.cfg.accessKeyId,
      secretAccessKey: args.cfg.secretAccessKey,
    },
  });

  const prefixes: string[] = [];
  let continuationToken: string | undefined = undefined;

  do {
    const resp: ListObjectsV2CommandOutput = await client.send(
      new ListObjectsV2Command({
        Bucket: args.bucket,
        Prefix: args.prefix,
        Delimiter: "/",
        ContinuationToken: continuationToken,
      })
    );

    for (const cp of resp.CommonPrefixes ?? []) {
      const p = cp.Prefix;
      if (!p) continue;
      const folder = normalizeFolderPrefix(p);
      if (!BACKUP_FOLDER_RE.test(`${folder}/`)) {
        // CommonPrefixes includes trailing slash; validate against the regex that allows optional '/'.
        continue;
      }
      prefixes.push(folder);
    }

    continuationToken = resp.IsTruncated ? resp.NextContinuationToken : undefined;
  } while (continuationToken);

  if (prefixes.length === 0) {
    throw new Error(
      `No backup folders found in s3://${args.bucket}/${args.prefix ?? ""} (expected prefixes like db-YYYY-MM-DD-HH:MM:SS-full/)`
    );
  }

  let bestFolder = "";

  for (const folder of prefixes) {
    if (!bestFolder) {
      bestFolder = folder;
      continue;
    }
    if (compareBackupFolders(folder, bestFolder) > 0) {
      bestFolder = folder;
    }
  }

  const destination = `s3://${args.bucket}/${bestFolder}`;
  return {
    destination,
    chosenPrefix: `${bestFolder}/`,
  };
}
