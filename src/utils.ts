import chalk from 'chalk';
import { execa } from 'execa';

export async function ensureBinaryExists(binaryName: string, versionArg: string[] = ['version']): Promise<void> {
  try {
    await execa(binaryName, versionArg, { stdio: 'ignore' });
  } catch {
    throw new Error(`Required binary not found: ${binaryName}. Please install it and ensure it's on your PATH.`);
  }
}

export function logInfo(message: string): void {
  console.log(chalk.cyan(message));
}

export function logSuccess(message: string): void {
  console.log(chalk.green(message));
}

export function logWarn(message: string): void {
  console.log(chalk.yellow(message));
}

export function logError(message: string, err?: unknown): void {
  console.error(chalk.red(message));
  if (err instanceof Error) {
    console.error(chalk.gray(err.message));
  }
}

export async function run(cmd: string, args: string[], opts: { stdio?: 'inherit' | 'pipe'; env?: NodeJS.ProcessEnv } = {}): Promise<void> {
  await execa(cmd, args, { stdio: opts.stdio ?? 'inherit', env: opts.env });
}


