import { execFile } from "child_process";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

export class KubectlError extends Error {
  constructor(
    message: string,
    readonly exitCode: number | null,
    readonly stderr: string
  ) {
    super(message);
    this.name = "KubectlError";
  }
}

function kubeconfigPath(): string {
  const k = process.env.KUBECONFIG?.trim();
  if (!k) {
    throw new Error(
      "KUBECONFIG is not set. In WSL: export KUBECONFIG=/path/to/kubeconfig"
    );
  }
  return k;
}

export async function kubectlJson<T = unknown>(
  args: string[],
  namespace?: string
): Promise<T> {
  const nsArgs = namespace ? ["-n", namespace] : [];
  const full = ["--kubeconfig", kubeconfigPath(), ...args, ...nsArgs, "-o", "json"];
  try {
    const { stdout, stderr } = await execFileAsync("kubectl", full, {
      maxBuffer: 32 * 1024 * 1024,
      encoding: "utf8",
    });
    if (stderr && /error|unable|forbidden/i.test(stderr) && !stdout.trim()) {
      throw new KubectlError(stderr.trim(), null, stderr);
    }
    return JSON.parse(stdout) as T;
  } catch (e: unknown) {
    if (e instanceof KubectlError) throw e;
    const err = e as { code?: number; stderr?: string; message?: string };
    const stderr = typeof err.stderr === "string" ? err.stderr : "";
    const code = typeof err.code === "number" ? err.code : null;
    if (code !== null && code !== 0) {
      throw new KubectlError(
        stderr || err.message || `kubectl exited ${code}`,
        code,
        stderr
      );
    }
    throw e;
  }
}

export async function kubectlText(
  args: string[],
  namespace?: string
): Promise<string> {
  const nsArgs = namespace ? ["-n", namespace] : [];
  const full = ["--kubeconfig", kubeconfigPath(), ...args, ...nsArgs];
  try {
    const { stdout, stderr } = await execFileAsync("kubectl", full, {
      maxBuffer: 32 * 1024 * 1024,
      encoding: "utf8",
    });
    return (stdout + (stderr ? `\n${stderr}` : "")).trimEnd();
  } catch (e: unknown) {
    const err = e as { stderr?: string; message?: string; code?: number };
    throw new KubectlError(
      err.stderr || err.message || "kubectl failed",
      err.code ?? null,
      err.stderr || ""
    );
  }
}
