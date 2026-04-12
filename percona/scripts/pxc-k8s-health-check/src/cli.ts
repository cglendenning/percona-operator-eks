#!/usr/bin/env node
import { collectFindings, clusterContextSummary } from "./collect";
import { buildPrescriptions, summaryLine } from "./diagnose";

function printReport(ns: string, findings: import("./types").Finding[]): void {
  const line = "=".repeat(72);
  console.log(line);
  console.log("Percona PXC / Kubernetes namespace health report (read-only)");
  console.log(`Namespace: ${ns}`);
  console.log(`Time (UTC): ${new Date().toISOString()}`);
  console.log(line);

  const order: Record<string, number> = { fail: 0, warn: 1, info: 2, ok: 3 };
  const sorted = [...findings].sort(
    (a, b) => order[a.severity] - order[b.severity]
  );

  for (const f of sorted) {
    const tag = f.severity.toUpperCase().padEnd(4);
    console.log(`[${tag}] ${f.title}`);
    const detail =
      f.detail == null || f.detail === ""
        ? ""
        : typeof f.detail === "string"
          ? f.detail
          : (() => {
              try {
                return JSON.stringify(f.detail);
              } catch {
                return String(f.detail);
              }
            })();
    if (detail) console.log(`       ${detail.replace(/\n/g, "\n       ")}`);
  }

  console.log(line);
  console.log("SUMMARY");
  console.log(summaryLine(findings));
  console.log(line);

  const rx = buildPrescriptions(ns, findings);
  console.log("DIAGNOSIS & PRESCRIPTIONS (copy/paste; review before running)\n");

  rx.forEach((p, i) => {
    console.log(`--- ${i + 1}. ${p.title} ---`);
    console.log("Probable root cause:");
    console.log(`  ${p.probableRootCause}\n`);
    console.log("Commands:");
    for (const c of p.commands) {
      console.log("");
      console.log("```bash");
      console.log(c);
      console.log("```");
    }
    if (p.notes?.length) {
      console.log("\nNotes:");
      p.notes.forEach((n) => console.log(`  - ${n}`));
    }
    console.log("");
  });

  console.log(line);
  console.log("Disclaimer: This tool only runs read-only kubectl queries.");
  console.log("It does not modify the cluster. Diagnosis is heuristic, not definitive.");
  console.log(line);
}

async function main(): Promise<void> {
  const ns = process.argv[2]?.trim();
  if (!ns || ns === "-h" || ns === "--help") {
    console.error(`Usage: node dist/cli.js <namespace>

Requires:
  - kubectl on PATH (WSL/Linux/macOS)
  - KUBECONFIG environment variable set to your kubeconfig file

Example (WSL):
  export KUBECONFIG=/mnt/c/Users/you/.kube/config
  npm run build && node dist/cli.js percona
`);
    process.exit(ns ? 0 : 1);
  }

  if (!process.env.KUBECONFIG?.trim()) {
    console.error("Error: KUBECONFIG is not set.");
    process.exit(1);
  }

  console.log(await clusterContextSummary());
  console.log("");

  const findings = await collectFindings(ns);
  printReport(ns, findings);

  const failed = findings.some((f) => f.severity === "fail");
  process.exit(failed ? 2 : 0);
}

main().catch((e: unknown) => {
  console.error(e instanceof Error ? e.message : String(e));
  process.exit(1);
});
