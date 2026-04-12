export type Severity = "ok" | "warn" | "fail" | "info";

export type Finding = {
  severity: Severity;
  code: string;
  title: string;
  /** Prefer string; CLI tolerates non-strings from unusual API shapes. */
  detail: string | unknown;
};

export type Prescription = {
  title: string;
  probableRootCause: string;
  commands: string[];
  notes?: string[];
};

export type HealthReport = {
  namespace: string;
  timestamp: string;
  findings: Finding[];
  prescriptions: Prescription[];
  summaryLine: string;
};
