package io.github.ghosthack.ffmpegffm;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.lang.foreign.Arena;
import java.lang.foreign.Linker;
import java.lang.foreign.SymbolLookup;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.List;

/**
 * Resolves the FFmpeg shared libraries the generated {@code FFmpeg} stubs bind to.
 *
 * <p>Resolution order:
 * <ol>
 *   <li>{@code -Dffmpegffm.libdir=<dir>} or {@code FFMPEG_FFM_LIBDIR} env var — load an
 *       existing FFmpeg install from that directory (e.g. a system package);</li>
 *   <li>bundled natives — the {@code ffmpeg-ffm-natives} classifier jar for this platform,
 *       extracted once to {@code ~/.cache/ffmpeg-ffm/<version>-<platform>/} and loaded in
 *       dependency order;</li>
 *   <li>{@link SymbolLookup#loaderLookup()} and the native linker's default lookup, so
 *       libraries pre-loaded by the host application still resolve.</li>
 * </ol>
 */
public final class FfmpegLibs {

    private static final Arena LIBRARY_ARENA = Arena.ofAuto();
    private static volatile SymbolLookup lookup;

    private FfmpegLibs() {}

    public static SymbolLookup lookup() {
        SymbolLookup l = lookup;
        if (l == null) {
            synchronized (FfmpegLibs.class) {
                l = lookup;
                if (l == null) {
                    lookup = l = resolve();
                }
            }
        }
        return l;
    }

    private static SymbolLookup resolve() {
        String override = System.getProperty("ffmpegffm.libdir", System.getenv("FFMPEG_FFM_LIBDIR"));
        SymbolLookup resolved = override != null ? fromDirectory(Path.of(override)) : fromBundle();
        SymbolLookup fallback = SymbolLookup.loaderLookup()
                .or(Linker.nativeLinker().defaultLookup());
        return resolved != null ? resolved.or(fallback) : fallback;
    }

    /** Chain every FFmpeg-looking shared library in {@code dir}, avutil-family first. */
    private static SymbolLookup fromDirectory(Path dir) {
        if (!Files.isDirectory(dir)) {
            throw new IllegalStateException("ffmpegffm.libdir does not exist: " + dir);
        }
        List<Path> libs = new ArrayList<>();
        try (var files = Files.list(dir)) {
            files.filter(FfmpegLibs::isFfmpegLibrary).sorted().forEach(libs::add);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        if (libs.isEmpty()) {
            throw new IllegalStateException("no FFmpeg shared libraries found in " + dir);
        }
        // Dependency order: avutil before the libs that link against it.
        libs.sort((a, b) -> Integer.compare(loadRank(a), loadRank(b)));
        return chain(libs);
    }

    private static boolean isFfmpegLibrary(Path p) {
        String n = p.getFileName().toString();
        boolean nativeExt = n.endsWith(".dylib") || n.endsWith(".dll") || n.contains(".so");
        return nativeExt && (n.startsWith("libav") || n.startsWith("libsw")
                || n.startsWith("av") || n.startsWith("sw"));
    }

    private static int loadRank(Path p) {
        String n = p.getFileName().toString();
        if (n.contains("avutil")) return 0;
        if (n.contains("swresample")) return 1;
        if (n.contains("avcodec")) return 2;
        if (n.contains("avformat")) return 3;
        return 4;
    }

    /** Extract this platform's bundled libraries to the cache dir and load them in manifest order. */
    private static SymbolLookup fromBundle() {
        String classifier = classifier();
        String base = "natives/" + classifier + "/";
        List<String> manifest = readManifest(base);
        if (manifest == null) {
            return null; // no natives jar on the classpath; fall back to loader/default lookup
        }
        Path cacheDir = Path.of(System.getProperty("user.home"), ".cache", "ffmpeg-ffm",
                Version.VERSION + "-" + classifier);
        try {
            Files.createDirectories(cacheDir);
            List<Path> libs = new ArrayList<>();
            for (String name : manifest) {
                libs.add(extract(base + name, cacheDir.resolve(name)));
            }
            return chain(libs);
        } catch (IOException e) {
            throw new UncheckedIOException("failed to extract bundled FFmpeg natives to " + cacheDir, e);
        }
    }

    private static List<String> readManifest(String base) {
        try (InputStream in = FfmpegLibs.class.getClassLoader().getResourceAsStream(base + "manifest.txt")) {
            if (in == null) {
                return null;
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8).lines()
                    .map(String::trim).filter(s -> !s.isEmpty()).toList();
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private static Path extract(String resource, Path target) throws IOException {
        try (InputStream in = FfmpegLibs.class.getClassLoader().getResourceAsStream(resource)) {
            if (in == null) {
                throw new IOException("missing classpath resource " + resource);
            }
            byte[] bytes = in.readAllBytes();
            if (Files.exists(target) && Files.size(target) == bytes.length) {
                return target;
            }
            Path tmp = Files.createTempFile(target.getParent(), target.getFileName().toString(), ".tmp");
            Files.write(tmp, bytes);
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
            return target;
        }
    }

    private static SymbolLookup chain(List<Path> libs) {
        SymbolLookup result = null;
        for (Path lib : libs) {
            SymbolLookup one = SymbolLookup.libraryLookup(lib.toAbsolutePath().toString(), LIBRARY_ARENA);
            result = result == null ? one : result.or(one);
        }
        return result;
    }

    static String classifier() {
        String os = System.getProperty("os.name", "").toLowerCase();
        String arch = System.getProperty("os.arch", "").toLowerCase();
        String osPart = os.contains("mac") ? "macos" : os.contains("win") ? "windows" : "linux";
        String archPart = (arch.equals("aarch64") || arch.equals("arm64")) ? "arm64" : "x64";
        return osPart + "-" + archPart;
    }
}
