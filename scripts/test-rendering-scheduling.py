#!/usr/bin/env python3
"""Run rendering scheduling regressions with a macOS GUI session and Metal device."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Save the regression results as JSON.")
    arguments = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    source_directory = repository / "Sources" / "QLaunchpad"
    worker = (source_directory / "FolderDepthBackdrop.swift").read_text()
    anchor = "        let blurRadiusPoints: Float = 16.0"
    if worker.count(anchor) != 1:
        raise RuntimeError("The GPU command gate needs to be updated for the current worker.")
    worker = worker.replace(
        anchor,
        "        BackdropGenerationFixture.shared.gate(commandBuffer, generation: generation)\n" + anchor,
        1,
    )
    completion = worker.index("        commandBuffer.addCompletedHandler")
    callback = worker.index("            self.queue.async {", completion) + len("            self.queue.async {")
    worker = worker[:callback] + "\n                BackdropGenerationFixture.shared.completed(generation)" + worker[callback:]
    provider = (source_directory / "FolderDrawableProvider.swift").read_text()
    fixture = (repository / "Tests" / "Rendering" / "FolderSchedulingRegression.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="qlaunch-rendering-regression-") as directory:
        temporary = Path(directory).resolve()
        swift_source = temporary / "Regression.swift"
        swift_source.write_text(worker + "\n" + provider + "\n" + fixture)
        executable = temporary / "Regression"
        subprocess.run(
            ["swiftc", "-O", "-parse-as-library", "-swift-version", "5",
             "-module-cache-path", str(temporary / "module-cache"),
             str(swift_source), "-o", str(executable)],
            check=True, timeout=120,
        )
        result_path = temporary / "result.json"
        subprocess.run([str(executable), str(result_path)], check=True, timeout=20)
        result = json.loads(result_path.read_text())
        if arguments.output:
            arguments.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        if not result["pass"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
