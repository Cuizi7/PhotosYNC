# Portable Live Photo fixtures

These files contain only project-generated 16 × 16 color blocks, synthetic
metadata, and (in `paired.mov`) a 440 Hz test tone. There are no user photographs,
Photos identifiers, location tags, or captured microphone samples. The generated
media is dedicated to the public domain under CC0 1.0; the generator follows the
repository's code license. `manifest.json` binds the frozen bytes and expectations.

Normal tests read these committed files. Authoring a replacement is explicit:

```sh
xcrun swiftc -parse-as-library Tests/Fixtures/LivePhotoPortable/generate.swift \
  -o work/generate-portable-media
work/generate-portable-media "$PWD/work/new-portable-media"
```

The destination must not exist. SDK/codec changes can change encoded bytes; never
regenerate fixtures during validation or update hashes merely to silence a failure.
Review metadata and expectations before freezing new bytes. The ordinary movies
exercise durations immediately below, exactly at, and above 10 seconds. The
corrupt files are deliberately small text files with media extensions.
