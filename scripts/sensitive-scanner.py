#!/usr/bin/env python3
"""
Sensitive Data Scanner
Scans directories for sensitive information and optionally redacts it.
"""

import argparse
import os
import re
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import List, Dict, Set, Tuple
from collections import defaultdict

# ANSI colors
RED = '\033[91m'
GREEN = '\033[92m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
CYAN = '\033[96m'
RESET = '\033[0m'
BOLD = '\033[1m'

@dataclass
class Finding:
    file_path: str
    line_number: int
    line_content: str
    match_type: str
    matched_value: str
    start_pos: int
    end_pos: int

# Built-in patterns for sensitive data detection
PATTERNS = {
    # Network identifiers
    'ipv4_address': r'\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b',
    'ipv6_address': r'\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b|\b(?:[0-9a-fA-F]{1,4}:){1,7}:|\b(?:[0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}\b',
    'dns_name': r'\b(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+(?:com|org|net|io|dev|cloud|local|internal|corp|lan|home|edu|gov|mil|co|us|uk|de|fr|jp|cn|au|ca|in|br|mx|ru|nl|se|no|fi|dk|ch|at|be|es|it|pl|cz|hu|ro|bg|hr|sk|si|lt|lv|ee|ie|pt|gr|tr|il|ae|sa|sg|hk|tw|kr|nz|za|ar|cl|co|pe|ve|ec|uy|py|bo)\b',
    
    # Credentials and secrets
    'email_address': r'\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b',
    'aws_access_key': r'\b(?:AKIA|ABIA|ACCA|ASIA)[0-9A-Z]{16}\b',
    'aws_secret_key': r'\b[a-zA-Z0-9/+=]{40}\b',
    'generic_api_key': r'(?i)(?:api[_-]?key|apikey|api[_-]?secret|api[_-]?token)["\']?\s*[:=]\s*["\']?([a-zA-Z0-9_\-]{20,})["\']?',
    'generic_secret': r'(?i)(?:secret|token|password|passwd|pwd|auth|credential)["\']?\s*[:=]\s*["\']?([^\s"\']{8,})["\']?',
    'private_key_block': r'-----BEGIN (?:RSA |DSA |EC |OPENSSH |PGP )?PRIVATE KEY-----',
    'jwt_token': r'\beyJ[a-zA-Z0-9_-]*\.eyJ[a-zA-Z0-9_-]*\.[a-zA-Z0-9_-]*\b',
    
    # Database connection strings
    'connection_string': r'(?i)(?:mysql|postgres|postgresql|mongodb|redis|sqlserver|mssql)://[^\s<>"]+',
    'jdbc_connection': r'jdbc:[a-z]+://[^\s<>"]+',
    
    # URLs with embedded credentials
    'url_with_creds': r'(?i)(?:https?|ftp|ssh)://[a-zA-Z0-9._-]+:[^\s@]+@[^\s<>"]+',
    
    # Personal identifiable information
    'us_ssn': r'\b\d{3}-\d{2}-\d{4}\b',
    'credit_card': r'\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|6(?:011|5[0-9]{2})[0-9]{12})\b',
    'us_phone': r'\b(?:\+1[-.\s]?)?\(?[0-9]{3}\)?[-.\s]?[0-9]{3}[-.\s]?[0-9]{4}\b',
    
    # Cloud and infrastructure
    'azure_connection': r'DefaultEndpointsProtocol=https;AccountName=[^;]+;AccountKey=[^;]+',
    'gcp_service_account': r'"type"\s*:\s*"service_account"',
    'docker_auth': r'"auth"\s*:\s*"[a-zA-Z0-9+/=]+"',
    'kubernetes_token': r'(?i)(?:bearer\s+)?[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}',
    
    # Common config patterns
    'env_secret': r'(?i)(?:export\s+)?(?:[A-Z_]*(?:SECRET|TOKEN|PASSWORD|API_KEY|APIKEY|ACCESS_KEY|PRIVATE_KEY)[A-Z_]*)\s*=\s*["\']?([^\s"\']+)["\']?',
    'base64_secret': r'(?i)(?:secret|password|token|key)["\']?\s*[:=]\s*["\']?([A-Za-z0-9+/]{40,}={0,2})["\']?',
    
    # GitHub/GitLab tokens
    'github_token': r'\b(?:ghp_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}|gho_[a-zA-Z0-9]{36}|ghu_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|ghr_[a-zA-Z0-9]{36})\b',
    'gitlab_token': r'\bglpat-[a-zA-Z0-9\-_]{20,}\b',
    
    # Slack tokens
    'slack_token': r'\bxox[baprs]-[0-9]{10,}-[0-9]{10,}-[a-zA-Z0-9]{24}\b',
    
    # Stripe keys
    'stripe_key': r'\b(?:sk_live_|pk_live_|sk_test_|pk_test_)[a-zA-Z0-9]{24,}\b',
}

# File extensions to skip (binary files, images, etc.)
SKIP_EXTENSIONS = {
    '.png', '.jpg', '.jpeg', '.gif', '.ico', '.svg', '.webp', '.bmp', '.tiff',
    '.mp3', '.mp4', '.avi', '.mov', '.mkv', '.wav', '.flac',
    '.zip', '.tar', '.gz', '.bz2', '.xz', '.7z', '.rar',
    '.exe', '.dll', '.so', '.dylib', '.bin', '.o', '.a',
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.woff', '.woff2', '.ttf', '.eot', '.otf',
    '.pyc', '.pyo', '.class', '.jar',
    '.sqlite', '.db', '.mdb',
    '.lock', '.sum',
}

# Directories to skip
SKIP_DIRS = {
    '.git', 'node_modules', '__pycache__', '.venv', 'venv', 'env',
    '.idea', '.vscode', '.cache', 'dist', 'build', '.tox',
    'vendor', 'target', '.gradle', '.mvn',
}

# Known safe/false positive patterns to ignore
SAFE_PATTERNS = {
    '127.0.0.1', '0.0.0.0', '255.255.255.255', '::1',
    'localhost', 'example.com', 'example.org', 'example.net',
    'test.com', 'test.local', 'foo.bar', 'placeholder',
}


class SensitiveScanner:
    def __init__(self, custom_keywords: List[str] = None, include_patterns: List[str] = None, 
                 exclude_patterns: List[str] = None, skip_safe: bool = True):
        self.custom_keywords = custom_keywords or []
        self.include_patterns = include_patterns or list(PATTERNS.keys())
        self.exclude_patterns = set(exclude_patterns or [])
        self.skip_safe = skip_safe
        self.findings: List[Finding] = []
        self.compiled_patterns: Dict[str, re.Pattern] = {}
        
        # Compile patterns
        for name in self.include_patterns:
            if name in PATTERNS and name not in self.exclude_patterns:
                try:
                    self.compiled_patterns[name] = re.compile(PATTERNS[name])
                except re.error as e:
                    print(f"{YELLOW}Warning: Invalid pattern '{name}': {e}{RESET}")
        
        # Add custom keywords
        for keyword in self.custom_keywords:
            pattern_name = f"keyword:{keyword}"
            try:
                self.compiled_patterns[pattern_name] = re.compile(re.escape(keyword), re.IGNORECASE)
            except re.error as e:
                print(f"{YELLOW}Warning: Invalid keyword '{keyword}': {e}{RESET}")

    def should_skip_file(self, file_path: Path) -> bool:
        """Check if file should be skipped based on extension or name."""
        if file_path.suffix.lower() in SKIP_EXTENSIONS:
            return True
        if file_path.name.startswith('.'):
            return True
        return False

    def should_skip_dir(self, dir_name: str) -> bool:
        """Check if directory should be skipped."""
        return dir_name in SKIP_DIRS or dir_name.startswith('.')

    def is_safe_match(self, matched_value: str) -> bool:
        """Check if the match is a known safe/false positive."""
        if not self.skip_safe:
            return False
        lower_value = matched_value.lower()
        return any(safe.lower() in lower_value for safe in SAFE_PATTERNS)

    def scan_line(self, line: str, line_number: int, file_path: str) -> List[Finding]:
        """Scan a single line for sensitive data."""
        findings = []
        
        for pattern_name, pattern in self.compiled_patterns.items():
            for match in pattern.finditer(line):
                matched_value = match.group(0)
                
                # Skip safe patterns
                if self.is_safe_match(matched_value):
                    continue
                
                # For patterns with groups, get the captured group if available
                if match.groups():
                    matched_value = match.group(1) or matched_value
                
                findings.append(Finding(
                    file_path=file_path,
                    line_number=line_number,
                    line_content=line.rstrip('\n\r'),
                    match_type=pattern_name,
                    matched_value=matched_value,
                    start_pos=match.start(),
                    end_pos=match.end()
                ))
        
        return findings

    def scan_file(self, file_path: Path) -> List[Finding]:
        """Scan a file for sensitive data."""
        findings = []
        
        try:
            with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                for line_number, line in enumerate(f, 1):
                    findings.extend(self.scan_line(line, line_number, str(file_path)))
        except (IOError, OSError) as e:
            print(f"{YELLOW}Warning: Could not read {file_path}: {e}{RESET}")
        except Exception as e:
            print(f"{YELLOW}Warning: Error scanning {file_path}: {e}{RESET}")
        
        return findings

    def scan_directory(self, directory: Path, show_progress: bool = True) -> List[Finding]:
        """Recursively scan a directory for sensitive data."""
        self.findings = []
        files_scanned = 0
        
        if show_progress:
            print(f"{CYAN}Scanning {directory}...{RESET}")
        
        for root, dirs, files in os.walk(directory):
            # Filter out directories to skip
            dirs[:] = [d for d in dirs if not self.should_skip_dir(d)]
            
            for filename in files:
                file_path = Path(root) / filename
                
                if self.should_skip_file(file_path):
                    continue
                
                file_findings = self.scan_file(file_path)
                self.findings.extend(file_findings)
                files_scanned += 1
                
                if show_progress and files_scanned % 100 == 0:
                    print(f"  Scanned {files_scanned} files...", end='\r')
        
        if show_progress:
            print(f"  Scanned {files_scanned} files.        ")
        
        return self.findings

    def print_findings(self):
        """Print all findings in a readable format."""
        if not self.findings:
            print(f"\n{GREEN}No sensitive data found.{RESET}")
            return
        
        # Group findings by file
        by_file: Dict[str, List[Finding]] = defaultdict(list)
        for finding in self.findings:
            by_file[finding.file_path].append(finding)
        
        # Group by type for summary
        by_type: Dict[str, int] = defaultdict(int)
        for finding in self.findings:
            by_type[finding.match_type] += 1
        
        print(f"\n{BOLD}{'='*70}{RESET}")
        print(f"{BOLD}{RED}SENSITIVE DATA FINDINGS{RESET}")
        print(f"{BOLD}{'='*70}{RESET}")
        
        # Print summary
        print(f"\n{BOLD}Summary by type:{RESET}")
        for match_type, count in sorted(by_type.items(), key=lambda x: -x[1]):
            display_type = match_type.replace('_', ' ').title()
            print(f"  {YELLOW}{display_type}:{RESET} {count} occurrences")
        
        print(f"\n{BOLD}Total: {len(self.findings)} findings in {len(by_file)} files{RESET}")
        
        # Print detailed findings
        print(f"\n{BOLD}{'='*70}{RESET}")
        print(f"{BOLD}Detailed Findings:{RESET}")
        print(f"{BOLD}{'='*70}{RESET}")
        
        for file_path, file_findings in sorted(by_file.items()):
            print(f"\n{BLUE}{file_path}{RESET}")
            print("-" * min(len(file_path), 70))
            
            for f in sorted(file_findings, key=lambda x: x.line_number):
                match_type = f.match_type.replace('_', ' ').title()
                # Truncate long lines
                line_preview = f.line_content[:100] + ('...' if len(f.line_content) > 100 else '')
                
                print(f"  Line {f.line_number}: [{YELLOW}{match_type}{RESET}]")
                print(f"    Match: {RED}{f.matched_value}{RESET}")
                print(f"    Context: {line_preview}")

    def get_unique_values(self) -> Dict[str, Set[str]]:
        """Get unique matched values grouped by type."""
        unique: Dict[str, Set[str]] = defaultdict(set)
        for finding in self.findings:
            unique[finding.match_type].add(finding.matched_value)
        return unique

    def redact_findings(self, dry_run: bool = False) -> Dict[str, int]:
        """Replace all findings with [REDACTED]. Returns count of replacements per file."""
        # Group findings by file
        by_file: Dict[str, List[Finding]] = defaultdict(list)
        for finding in self.findings:
            by_file[finding.file_path].append(finding)
        
        replacements: Dict[str, int] = {}
        
        for file_path, file_findings in by_file.items():
            try:
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    lines = f.readlines()
                
                # Get unique values to replace in this file
                values_to_replace = set(f.matched_value for f in file_findings)
                replacement_count = 0
                
                # Replace each unique value
                for i, line in enumerate(lines):
                    for value in values_to_replace:
                        if value in line:
                            lines[i] = line.replace(value, '[REDACTED]')
                            replacement_count += line.count(value)
                            line = lines[i]  # Update for subsequent replacements
                
                if not dry_run and replacement_count > 0:
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.writelines(lines)
                
                replacements[file_path] = replacement_count
                
            except (IOError, OSError) as e:
                print(f"{YELLOW}Warning: Could not process {file_path}: {e}{RESET}")
        
        return replacements


def interactive_redact(scanner: SensitiveScanner):
    """Interactively prompt user to redact findings."""
    if not scanner.findings:
        return
    
    print(f"\n{BOLD}{'='*70}{RESET}")
    print(f"{BOLD}REDACTION OPTIONS{RESET}")
    print(f"{BOLD}{'='*70}{RESET}")
    
    unique_values = scanner.get_unique_values()
    total_unique = sum(len(v) for v in unique_values.values())
    
    print(f"\nFound {total_unique} unique sensitive values.")
    print("\nOptions:")
    print(f"  {GREEN}1{RESET} - Redact ALL findings")
    print(f"  {GREEN}2{RESET} - Redact by type")
    print(f"  {GREEN}3{RESET} - Review each unique value")
    print(f"  {GREEN}4{RESET} - Dry run (show what would be changed)")
    print(f"  {GREEN}5{RESET} - Exit without changes")
    
    while True:
        choice = input(f"\n{CYAN}Enter choice (1-5): {RESET}").strip()
        
        if choice == '1':
            confirm = input(f"{YELLOW}Are you sure you want to redact ALL {len(scanner.findings)} findings? (yes/no): {RESET}")
            if confirm.lower() == 'yes':
                results = scanner.redact_findings()
                total = sum(results.values())
                print(f"\n{GREEN}Redacted {total} occurrences in {len(results)} files.{RESET}")
            else:
                print("Cancelled.")
            break
            
        elif choice == '2':
            print("\nTypes found:")
            types = list(unique_values.keys())
            for i, t in enumerate(types, 1):
                display_type = t.replace('_', ' ').title()
                print(f"  {i}. {display_type} ({len(unique_values[t])} unique values)")
            
            type_choices = input(f"\n{CYAN}Enter type numbers to redact (comma-separated, or 'all'): {RESET}").strip()
            
            if type_choices.lower() == 'all':
                selected_types = set(types)
            else:
                try:
                    indices = [int(x.strip()) - 1 for x in type_choices.split(',')]
                    selected_types = set(types[i] for i in indices if 0 <= i < len(types))
                except (ValueError, IndexError):
                    print("Invalid selection.")
                    continue
            
            # Filter findings to selected types
            original_findings = scanner.findings
            scanner.findings = [f for f in original_findings if f.match_type in selected_types]
            
            confirm = input(f"{YELLOW}Redact {len(scanner.findings)} findings? (yes/no): {RESET}")
            if confirm.lower() == 'yes':
                results = scanner.redact_findings()
                total = sum(results.values())
                print(f"\n{GREEN}Redacted {total} occurrences in {len(results)} files.{RESET}")
            else:
                print("Cancelled.")
            
            scanner.findings = original_findings
            break
            
        elif choice == '3':
            values_to_redact = set()
            
            for match_type, values in unique_values.items():
                display_type = match_type.replace('_', ' ').title()
                print(f"\n{BOLD}Type: {display_type}{RESET}")
                
                for value in sorted(values):
                    display_value = value[:60] + ('...' if len(value) > 60 else '')
                    response = input(f"  Redact '{RED}{display_value}{RESET}'? (y/n/q): ").strip().lower()
                    
                    if response == 'q':
                        break
                    elif response == 'y':
                        values_to_redact.add(value)
                else:
                    continue
                break
            
            if values_to_redact:
                # Filter findings to selected values
                original_findings = scanner.findings
                scanner.findings = [f for f in original_findings if f.matched_value in values_to_redact]
                
                results = scanner.redact_findings()
                total = sum(results.values())
                print(f"\n{GREEN}Redacted {total} occurrences in {len(results)} files.{RESET}")
                
                scanner.findings = original_findings
            break
            
        elif choice == '4':
            print("\n{BOLD}DRY RUN - No changes will be made:{RESET}")
            results = scanner.redact_findings(dry_run=True)
            for file_path, count in sorted(results.items()):
                print(f"  {file_path}: {count} replacements")
            print(f"\n{YELLOW}Total: {sum(results.values())} replacements would be made{RESET}")
            
        elif choice == '5':
            print("Exiting without changes.")
            break
        else:
            print("Invalid choice. Please enter 1-5.")


def main():
    parser = argparse.ArgumentParser(
        description='Scan directories for sensitive information',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
Examples:
  %(prog)s /path/to/scan
  %(prog)s /path/to/scan -k "secret-password" "internal.domain.com"
  %(prog)s /path/to/scan --only ipv4_address dns_name email_address
  %(prog)s /path/to/scan --exclude us_phone credit_card
  %(prog)s /path/to/scan --list-patterns

Available patterns:
  ''' + ', '.join(sorted(PATTERNS.keys()))
    )
    
    parser.add_argument('directory', nargs='?', help='Directory to scan')
    parser.add_argument('-k', '--keywords', nargs='+', default=[], 
                        help='Custom keywords to search for')
    parser.add_argument('--only', nargs='+', metavar='PATTERN',
                        help='Only use these patterns (see --list-patterns)')
    parser.add_argument('--exclude', nargs='+', metavar='PATTERN', default=[],
                        help='Exclude these patterns from scanning')
    parser.add_argument('--include-safe', action='store_true',
                        help='Include matches that are typically safe (localhost, example.com, etc.)')
    parser.add_argument('--no-interactive', action='store_true',
                        help='Just print findings without redaction prompt')
    parser.add_argument('--list-patterns', action='store_true',
                        help='List all available patterns and exit')
    parser.add_argument('--json', action='store_true',
                        help='Output findings as JSON')
    
    args = parser.parse_args()
    
    if args.list_patterns:
        print(f"\n{BOLD}Available detection patterns:{RESET}\n")
        for name, pattern in sorted(PATTERNS.items()):
            display_name = name.replace('_', ' ').title()
            print(f"  {CYAN}{name}{RESET}")
            print(f"    {display_name}")
            print(f"    Pattern: {pattern[:80]}{'...' if len(pattern) > 80 else ''}\n")
        return
    
    if not args.directory:
        parser.print_help()
        sys.exit(1)
    
    directory = Path(args.directory).resolve()
    
    if not directory.exists():
        print(f"{RED}Error: Directory does not exist: {directory}{RESET}")
        sys.exit(1)
    
    if not directory.is_dir():
        print(f"{RED}Error: Not a directory: {directory}{RESET}")
        sys.exit(1)
    
    # Determine which patterns to use
    include_patterns = args.only if args.only else list(PATTERNS.keys())
    
    # Validate pattern names
    invalid_patterns = [p for p in include_patterns if p not in PATTERNS]
    if invalid_patterns:
        print(f"{YELLOW}Warning: Unknown patterns ignored: {', '.join(invalid_patterns)}{RESET}")
        include_patterns = [p for p in include_patterns if p in PATTERNS]
    
    invalid_excludes = [p for p in args.exclude if p not in PATTERNS]
    if invalid_excludes:
        print(f"{YELLOW}Warning: Unknown exclude patterns ignored: {', '.join(invalid_excludes)}{RESET}")
    
    # Create scanner
    scanner = SensitiveScanner(
        custom_keywords=args.keywords,
        include_patterns=include_patterns,
        exclude_patterns=args.exclude,
        skip_safe=not args.include_safe
    )
    
    # Scan
    scanner.scan_directory(directory)
    
    # Output
    if args.json:
        import json
        output = [{
            'file': f.file_path,
            'line': f.line_number,
            'type': f.match_type,
            'value': f.matched_value,
            'context': f.line_content
        } for f in scanner.findings]
        print(json.dumps(output, indent=2))
    else:
        scanner.print_findings()
        
        if not args.no_interactive and scanner.findings:
            interactive_redact(scanner)


if __name__ == '__main__':
    main()

