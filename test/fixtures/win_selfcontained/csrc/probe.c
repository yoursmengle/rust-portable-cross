/*
 * Exercises the bundled C compiler on the Windows host target.
 *
 * Uses the C runtime (not just arithmetic) so that a broken CRT wiring shows up
 * here rather than only in Rust code: if the C objects and the Rust objects
 * disagree about which CRT they link against, this fails to link or misbehaves.
 */

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
