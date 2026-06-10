/*
 * gen-seccomp-bpf — Generic seccomp BPF filter compiler
 *
 * Reads a syscall allowlist from a file (one name per line) and
 * produces a binary BPF program suitable for bubblewrap's --seccomp flag.
 *
 * Runtime-agnostic. The syscall allowlist is determined by the caller
 * which composes abstract syscall categories.
 *
 * Usage:
 *   gen-seccomp-bpf <allowlist-file> > filter.bpf
 *
 * The allowlist file format:
 *   - One syscall name per line (e.g., "read", "write", "mmap")
 *   - Empty lines and lines starting with '#' are ignored
 *   - Syscall names must match libseccomp's naming (see seccomp_syscall_resolve_name)
 *
 * Default action for unlisted syscalls: EPERM (graceful, not SIGKILL)
 */

#include <errno.h>
#include <seccomp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_LINE 256

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <allowlist-file>\n", argv[0]);
        fprintf(stderr, "Reads syscall names (one per line) and outputs BPF to stdout.\n");
        return 1;
    }

    FILE *fp = fopen(argv[1], "r");
    if (!fp) {
        fprintf(stderr, "Cannot open %s: %s\n", argv[1], strerror(errno));
        return 1;
    }

    /* Default action: return EPERM for unlisted syscalls.
     * This allows the calling process to handle errors gracefully
     * rather than being killed by SIGSYS. */
    scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ERRNO(EPERM));
    if (!ctx) {
        fprintf(stderr, "seccomp_init failed\n");
        fclose(fp);
        return 1;
    }

    char line[MAX_LINE];
    int lineno = 0;
    int rules_added = 0;
    int rc;

    while (fgets(line, sizeof(line), fp)) {
        lineno++;

        /* Strip trailing newline/whitespace */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'
                           || line[len-1] == ' ' || line[len-1] == '\t'))
            line[--len] = '\0';

        /* Skip empty lines and comments */
        if (len == 0 || line[0] == '#')
            continue;

        /* Resolve syscall name to number */
        int syscall_nr = seccomp_syscall_resolve_name(line);
        if (syscall_nr == __NR_SCMP_ERROR) {
            fprintf(stderr, "Warning: unknown syscall '%s' at line %d (skipped)\n",
                    line, lineno);
            continue;
        }

        rc = seccomp_rule_add(ctx, SCMP_ACT_ALLOW, syscall_nr, 0);
        if (rc < 0) {
            fprintf(stderr, "Failed to add rule for '%s': %s\n",
                    line, strerror(-rc));
            seccomp_release(ctx);
            fclose(fp);
            return 1;
        }
        rules_added++;
    }
    fclose(fp);

    if (rules_added == 0) {
        fprintf(stderr, "Error: no syscall rules added (empty allowlist?)\n");
        seccomp_release(ctx);
        return 1;
    }

    fprintf(stderr, "Compiled %d syscall rules into BPF filter\n", rules_added);

    /* Export as raw BPF to stdout */
    rc = seccomp_export_bpf(ctx, STDOUT_FILENO);
    if (rc < 0) {
        fprintf(stderr, "seccomp_export_bpf failed: %s\n", strerror(-rc));
        seccomp_release(ctx);
        return 1;
    }

    seccomp_release(ctx);
    return 0;
}
