#!/usr/bin/env node
import { kubectlJson, kubectlText } from "./kubectl";

type PodList = {
  items: Array<{
    metadata: { name: string; labels?: Record<string, string | undefined> };
    status?: { phase?: string };
  }>;
};

function usage(exitCode: number): never {
  const msg = `Usage:
  node dist/cli.js --namespace <ns> --secret <name> [--cluster <name>] [--minutes <n>]

Requires:
  - kubectl on PATH (WSL/Linux/macOS)
  - KUBECONFIG environment variable set

Examples:
  export KUBECONFIG=~/.kube/config
  npm ci && npm run build
  node dist/cli.js --namespace percona --secret cluster1-secrets --cluster cluster1 --minutes 5
`;
  if (exitCode === 0) console.log(msg);
  else console.error(msg);
  process.exit(exitCode);
}

function parseArgs(argv: string[]): {
  namespace: string;
  cluster?: string;
  minutes: number;
  secret: string;
} {
  const out: { namespace?: string; cluster?: string; minutes?: number; secret?: string } =
    {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-h" || a === "--help") usage(0);
    if (a === "--namespace" || a === "-n") out.namespace = argv[++i];
    else if (a === "--cluster" || a === "-c") out.cluster = argv[++i];
    else if (a === "--minutes" || a === "-m") out.minutes = Number(argv[++i]);
    else if (a === "--secret" || a === "-s") out.secret = argv[++i];
    else {
      console.error(`Unknown arg: ${a}`);
      usage(1);
    }
  }
  const ns = out.namespace?.trim();
  if (!ns) {
    console.error("Error: --namespace is required");
    usage(1);
  }
  const minutes = out.minutes ?? 5;
  if (!Number.isFinite(minutes) || minutes <= 0) {
    throw new Error(`Invalid --minutes: ${String(out.minutes)}`);
  }
  const secret = out.secret?.trim();
  if (!secret) {
    console.error("Error: --secret is required");
    usage(1);
  }
  return { namespace: ns, cluster: out.cluster?.trim() || undefined, minutes, secret };
}

function fmtBytes(bytes: number): string {
  if (!Number.isFinite(bytes)) return "n/a";
  const u = ["B", "KiB", "MiB", "GiB", "TiB"];
  let v = bytes;
  let i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(i === 0 ? 0 : 2)} ${u[i]}`;
}

function parseDfKp(line: string): { sizeBytes: number; usedBytes: number; availBytes: number; usePct: string } {
  // df -kP output: Filesystem 1024-blocks Used Available Capacity Mounted on
  // We run awk to only output: size_k used_k avail_k usepct
  const parts = line.trim().split(/\s+/);
  if (parts.length < 4) throw new Error(`Unexpected df output: ${line}`);
  const sizeK = Number(parts[0]);
  const usedK = Number(parts[1]);
  const availK = Number(parts[2]);
  const usePct = String(parts[3]);
  if (![sizeK, usedK, availK].every((n) => Number.isFinite(n) && n >= 0)) {
    throw new Error(`Unexpected df numbers: ${line}`);
  }
  return {
    sizeBytes: sizeK * 1024,
    usedBytes: usedK * 1024,
    availBytes: availK * 1024,
    usePct,
  };
}

function shellEscapeSingleQuotes(s: string): string {
  // Wrap in single quotes; escape embedded single quotes for POSIX sh.
  // Example: abc'd -> 'abc'"'"'d'
  return `'${s.replace(/'/g, `'\"'\"'`)}'`;
}

async function execInPod(ns: string, pod: string, container: string, command: string): Promise<string> {
  // Use sh -lc so quoting behaves consistently across images
  return kubectlText(["exec", pod, "-c", container, "--", "sh", "-lc", command], ns);
}

async function getPxcPods(ns: string, cluster?: string): Promise<{ pods: string[]; discoveredCluster?: string }> {
  const baseSel = "app.kubernetes.io/name=percona-xtradb-cluster,app.kubernetes.io/component=pxc";
  const sel = cluster ? `${baseSel},app.kubernetes.io/instance=${cluster}` : baseSel;
  const pods = await kubectlJson<PodList>(["get", "pods", "-l", sel], ns);

  if (!cluster) {
    const instances = new Set<string>();
    for (const p of pods.items) {
      const inst = p.metadata.labels?.["app.kubernetes.io/instance"]?.trim();
      if (inst) instances.add(inst);
    }
    if (instances.size > 1) {
      const list = [...instances].sort().join(", ");
      throw new Error(
        `Multiple PXC clusters found in namespace ${ns}: ${list}. ` +
          `Pass --cluster to select one.`
      );
    }
  }

  const running = pods.items
    .filter((p) => (p.status?.phase ?? "") === "Running")
    .map((p) => p.metadata.name)
    .filter(Boolean);

  const discovered =
    cluster ||
    pods.items[0]?.metadata.labels?.["app.kubernetes.io/instance"] ||
    undefined;

  return { pods: running, discoveredCluster: discovered };
}

async function getSecretRootPassword(ns: string, secretName: string): Promise<string> {
  const raw = await kubectlText(
    ["get", "secret", secretName, "-o", "jsonpath={.data.root}"],
    ns
  );
  const b64 = raw.trim().replace(/^"|"$/g, "");
  if (!b64) throw new Error(`Secret ${secretName} has no .data.root`);
  const decoded = Buffer.from(b64, "base64").toString("utf8");
  if (!decoded) throw new Error(`Secret ${secretName} .data.root decoded empty`);
  return decoded;
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  if (!process.env.KUBECONFIG?.trim()) {
    throw new Error("KUBECONFIG is not set");
  }

  const { pods, discoveredCluster } = await getPxcPods(args.namespace, args.cluster);
  if (pods.length === 0) {
    throw new Error(
      `No running PXC pods found in namespace ${args.namespace}` +
        (args.cluster ? ` for cluster ${args.cluster}` : "")
    );
  }
  if (!discoveredCluster) {
    throw new Error("Could not determine cluster name (use --cluster)");
  }

  const rootPassword = await getSecretRootPassword(args.namespace, args.secret);

  const container = "pxc";
  const datadir = "/var/lib/mysql";

  console.log(`PXC binlog purge`);
  console.log(`Namespace: ${args.namespace}`);
  console.log(`Cluster: ${discoveredCluster}`);
  console.log(`Pods: ${pods.join(", ")}`);
  console.log(`Minutes: ${args.minutes}`);
  console.log(`Secret: ${args.secret} (key: root)`);
  console.log("");

  const results: Array<{
    pod: string;
    before: ReturnType<typeof parseDfKp>;
    after: ReturnType<typeof parseDfKp>;
    freedBytes: number;
    purgeOut: string;
  }> = [];

  for (const pod of pods) {
    const beforeLine = await execInPod(
      args.namespace,
      pod,
      container,
      `df -kP ${datadir} | awk 'NR==2 {print $2" "$3" "$4" "$5}'`
    );
    const before = parseDfKp(beforeLine.split("\n").pop() ?? beforeLine);

    const minutes = Math.floor(args.minutes);
    const rootPwQuoted = shellEscapeSingleQuotes(rootPassword);
    const queryQuoted = shellEscapeSingleQuotes(
      `PURGE BINARY LOGS BEFORE (NOW() - INTERVAL ${minutes} MINUTE); SELECT 'ok' AS result;`
    );
    const purgeOut = await execInPod(
      args.namespace,
      pod,
      container,
      `MYSQL_PWD=${rootPwQuoted} mysql -uroot -sN -e ${queryQuoted}`
    );

    const afterLine = await execInPod(
      args.namespace,
      pod,
      container,
      `df -kP ${datadir} | awk 'NR==2 {print $2" "$3" "$4" "$5}'`
    );
    const after = parseDfKp(afterLine.split("\n").pop() ?? afterLine);

    const freedBytes = Math.max(0, before.usedBytes - after.usedBytes);
    results.push({ pod, before, after, freedBytes, purgeOut });
  }

  // Print summary (aligned, not a markdown table)
  const pad = (s: string, n: number) => (s.length >= n ? s : s + " ".repeat(n - s.length));
  const podW = Math.max(...results.map((r) => r.pod.length), "pod".length);
  console.log(
    `${pad("pod", podW)}  before-used   after-used    freed       before%  after%`
  );
  console.log(`${"-".repeat(podW)}  ----------   ---------    -----       -------  ------`);
  for (const r of results) {
    console.log(
      `${pad(r.pod, podW)}  ${pad(fmtBytes(r.before.usedBytes), 11)}  ${pad(
        fmtBytes(r.after.usedBytes),
        11
      )}  ${pad(fmtBytes(r.freedBytes), 10)}  ${pad(r.before.usePct, 7)}  ${r.after.usePct}`
    );
  }
}

main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});

