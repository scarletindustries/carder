// Source of the committed `memtest.wasm` fixture — proves a TeaVM WASM GC Java guest can read/write
// RAW LINEAR MEMORY via org.teavm.interop.Address, running through carder on the BEAM. This is the
// mechanism a host ABI (e.g. Dance) relies on: the host writes argument bytes into the guest's
// linear memory at a pointer, the guest reads them, and vice-versa for replies.
//
// `memtest()` writes two bytes into linear memory at a fixed address and reads them back:
// 42 + 7 = 49 iff Address-based access works. The address 4096 is past TeaVM's ~211 B of static
// data, inside the malloc heap region, so the write cannot clobber the module's data segment.
//
// Rebuild (TeaVM 0.15.0, JDK 17+ to run the compiler; WASM GC Maven plugin with
// <targetType>WEBASSEMBLY_GC</targetType> and <mainClass>demo.Client</mainClass>):
//   mvn -q -B package        # → target/generated/wasm/teavm/classes.wasm  (this fixture)
package demo;

import org.teavm.interop.Address;
import org.teavm.interop.Export;

public class Memtest {

    @Export(name = "memtest")
    public static int memtest() {
        Address p = Address.fromInt(4096); // past TeaVM's ~211 B of static data, in the malloc heap region
        p.putByte((byte) 42);
        p.add(1).putByte((byte) 7);
        return (p.getByte() & 0xFF) + (p.add(1).getByte() & 0xFF);
    }

    public static void main(String[] args) {
        memtest();
    }
}
