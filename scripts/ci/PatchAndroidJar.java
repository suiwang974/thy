import org.objectweb.asm.*;
import java.io.*;
import java.util.zip.*;

/** Adds API-37-only android.* members referenced by plugins to a COPY of
 *  android.jar (compile-time only; runtime framework classes untouched).
 *  java.* gaps (Locale.of / Thread.threadId) are NOT patched here: they exist
 *  in android.jar already and are resolved by compiling Java with JDK 21+. */
public class PatchAndroidJar {
  public static void main(String[] a) throws Exception {
    String in = a[0], out = a[1];
    try (ZipFile zin = new ZipFile(in);
         ZipOutputStream zout = new ZipOutputStream(new FileOutputStream(out))) {
      var en = zin.entries();
      while (en.hasMoreElements()) {
        var e = en.nextElement();
        byte[] data = zin.getInputStream(e).readAllBytes();
        switch (e.getName()) {
          case "android/os/Build$VERSION_CODES.class" -> data = patch(data, (cv) ->
            cv.visitField(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC | Opcodes.ACC_FINAL,
              "CINNAMON_BUN", "I", null, 37));
          case "android/Manifest$permission.class" -> data = patch(data, (cv) ->
            cv.visitField(Opcodes.ACC_PUBLIC | Opcodes.ACC_STATIC | Opcodes.ACC_FINAL,
              "ACCESS_LOCAL_NETWORK", "Ljava/lang/String;", null,
              "android.permission.ACCESS_LOCAL_NETWORK"));
        }
        zout.putNextEntry(new ZipEntry(e.getName()));
        zout.write(data);
        zout.closeEntry();
      }
    }
    System.out.println("patched -> " + out);
  }

  interface Patcher { void add(ClassVisitor cv); }

  static byte[] patch(byte[] b, Patcher p) {
    ClassReader cr = new ClassReader(b);
    ClassWriter cw = new ClassWriter(cr, ClassWriter.COMPUTE_MAXS);
    cr.accept(new ClassVisitor(Opcodes.ASM9, cw) {
      @Override public void visitEnd() { p.add(cv); super.visitEnd(); }
    }, 0);
    return cw.toByteArray();
  }
}
