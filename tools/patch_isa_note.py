#!/usr/bin/env python3
"""Zero out the 'x86 ISA needed' property (0x0000c002) in ELF .note.gnu.property.
Host CRT objects inject an ISA level the 32-bit SFOS guest kernel can't satisfy."""
import sys
data = bytearray(open(sys.argv[1],'rb').read())
needle = bytes.fromhex('028000c004000000')
i = data.find(needle)
if i == -1:
    print('no ISA-needed property found; nothing to do'); sys.exit(0)
print(f'ISA needed value was 0x{data[i+8]:02x}; zeroing')
data[i+8] = 0x00
open(sys.argv[1],'wb').write(bytes(data))
