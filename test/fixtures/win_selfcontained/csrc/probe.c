/*
 * Exercises the bundled C compiler on the Windows host target.
 *
 * Uses the C runtime (not just arithmetic) so that a broken CRT wiring shows up
 * here rather than only in Rust code: if the C objects and the Rust objects
 * disagree about which CRT they link against, this fails to link or misbehaves.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int rpc_probe_add(int a, int b)
{
    return a + b;
}

/* Touches the CRT's allocator and string routines from the C side. */
int rpc_probe_crt(void)
{
    char *buffer = (char *)malloc(32);
    int length;

    if (buffer == 0) {
        return -1;
    }

    strcpy(buffer, "portable");
    length = (int)strlen(buffer);
    free(buffer);

    return length;
}

/*
 * Forces a stack frame larger than one page.
 *
 * The bundled C compiler targets the GNU ABI (see rust_build_x64_win_native.ps1),
 * so a frame this size makes it emit a call to the MinGW stack probe
 * ___chkstk_ms in the prologue. That symbol is resolved from rpc_winshim.lib,
 * which is the whole point of this probe: without it the link fails.
 *
 * The buffer's address has to escape to a non-inlinable callee, otherwise the
 * optimizer sinks the array and no probe is emitted at all.
 */
static int rpc_probe_consume(const volatile char *buffer, int length)
{
    int total = 0;
    int i;

    for (i = 0; i < length; i++) {
        total += buffer[i];
    }

    return total;
}

int rpc_probe_large_frame(int seed)
{
    char scratch[16384];
    int i;

    for (i = 0; i < (int)sizeof scratch; i++) {
        scratch[i] = (char)((i + seed) & 0x0f);
    }

    return rpc_probe_consume(scratch, (int)sizeof scratch)
        + scratch[0]
        + scratch[(sizeof scratch) - 1];
}

/*
 * Exercises the formatted I/O the shim supplies.
 *
 * ucrtbase.dll exports none of the printf or scanf family - in Microsoft's own
 * stdio.h they are inline bodies forwarding to __stdio_common_v*, so they never
 * become DLL exports. These calls link only because rpc_winshim.lib defines
 * them. The checks are on behaviour rather than just linking: a forwarder built
 * with the wrong option flag links fine and then silently misformats, so each
 * step returns a distinct code the Rust side reports.
 */
int rpc_probe_stdio(void)
{
    char buffer[32];
    char legacy[8];
    int written;
    int first = 0;
    int second = 0;

    /* sprintf: unbounded and null terminated. */
    written = sprintf(buffer, "%s-%d", "rpc", 42);
    if (written != 6) { return 1; }
    if (strcmp(buffer, "rpc-42") != 0) { return 2; }

    /* C99 snprintf: truncates, always terminates, returns the length it wanted. */
    memset(buffer, 'x', sizeof buffer);
    if (snprintf(buffer, 5, "%s", "abcdefgh") != 8) { return 3; }
    if (strcmp(buffer, "abcd") != 0) { return 4; }

    /* Legacy _snprintf: truncates without a terminator and returns -1. This is
     * the one that separates the two option flags. */
    memset(legacy, 'x', sizeof legacy);
    if (_snprintf(legacy, 4, "%s", "abcdefgh") != -1) { return 5; }
    if (legacy[0] != 'a' || legacy[3] != 'd' || legacy[4] != 'x') { return 6; }

    /* _scprintf: the length the output would have been, formatting nothing. */
    if (_scprintf("%s-%d", "rpc", 42) != 6) { return 7; }

    /* sscanf, through __stdio_common_vsscanf. */
    if (sscanf("17 25", "%d %d", &first, &second) != 2) { return 8; }
    if (first != 17 || second != 25) { return 9; }

    /* fprintf against a real stream, reached through __acrt_iob_func. */
    if (fprintf(stdout, "c-stdio: %d\n", 7) != 11) { return 10; }
    fflush(stdout);

    return 0;
}
