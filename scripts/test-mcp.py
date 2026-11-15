#!/usr/bin/env python3
"""Exercise the packaged MCP protocol and PDF-to-Typst flow with fictional data."""

import argparse
import json
import os
from pathlib import Path
import select
import shutil
import sqlite3
import subprocess
import tempfile


STYLES = ("source", "editorial", "classic", "minimal", "executive", "technical")


def write_cv_pdf(path, name):
    """Write a small PDF without depending on a PDF library or checking in a binary."""
    def pdf_string(value):
        return "(" + value.replace("\\", "\\\\").replace("(", r"\(").replace(")", r"\)") + ")"

    def stream(lines):
        text = " Tj 0 -30 Td ".join(pdf_string(line) for line in lines)
        data = f"BT /F1 14 Tf 60 750 Td {text} Tj ET\n".encode("ascii")
        return f"<< /Length {len(data)} >>\nstream\n".encode() + data + b"endstream"

    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R /Annots [8 0 R] >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        stream([name, "alex@example.invalid", "Professional Experience",
                "Platform Engineer | Example Studio", "2021 - 2024",
                '- Built #read("example.txt") with 3 engineers.']),
        stream(["Skills", "Swift, SQLite, Typst", "Education", "Example University"]),
        b"<< /Type /Annot /Subtype /Link /Rect [60 715 195 735] "
        b"/A << /S /URI /URI (https://example.invalid/portfolio) >> >>",
    ]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, data in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{number} 0 obj\n".encode() + data + b"\nendobj\n")
    xref = len(pdf)
    pdf.extend(f"xref\n0 {1 + len(offsets)}\n0000000000 65535 f \n".encode())
    for offset in offsets:
        pdf.extend(f"{offset:010d} 00000 n \n".encode())
    pdf.extend(f"trailer\n<< /Size {1 + len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    path.write_bytes(pdf)


class Client:
    def __init__(self, process):
        self.process = process
        self.next_id = 0

    def send(self, packet):
        self.process.stdin.write(json.dumps(packet).encode() + b"\n")
        self.process.stdin.flush()

    def response(self):
        ready, _, _ = select.select([self.process.stdout], [], [], 15)
        assert ready, "Timeout waiting for the MCP server"
        line = self.process.stdout.readline()
        assert line, "MCP server closed stdout"
        return json.loads(line)

    def request(self, method, params=None):
        self.next_id += 1
        packet = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            packet["params"] = params
        self.send(packet)
        response = self.response()
        assert response["id"] == self.next_id and response["jsonrpc"] == "2.0", response
        return response

    def tool(self, name, error=None, **arguments):
        reply = self.request("tools/call", {"name": name, "arguments": arguments})["result"]
        assert reply.get("isError", False) == (error is not None), reply
        block = reply["content"][0]
        assert block["type"] == "text", block
        if error is not None:
            assert error.casefold() in block["text"].casefold(), block
            return None
        structured = reply["structuredContent"]
        assert structured == json.loads(block["text"]), reply
        return structured


def verify_fixture_facts(vault, ids):
    # Mark only these known synthetic rows reviewed. The MCP interface is read only for facts.
    with sqlite3.connect(vault / "knowledge.sqlite3") as database:
        result = database.executemany("UPDATE facts SET status = 'verified' WHERE id = ?", ((i,) for i in ids))
        assert result.rowcount == len(ids), result.rowcount


def run(binary, temp):
    vault = temp / "Vault data"
    env = {**os.environ, "CV_VAULT_HOME": str(vault)}

    def import_pdf(path):
        command = [str(binary), "import-pdf", str(path)]
        return json.loads(subprocess.check_output(command, env=env, timeout=20))

    first_pdf = temp / "synthetic.pdf"
    second_pdf = temp / "second.pdf"
    write_cv_pdf(first_pdf, "Alex Example")
    write_cv_pdf(second_pdf, "Taylor Sample")
    imported = import_pdf(first_pdf)
    assert imported["source"]["pageCount"] == 2 and not imported["isDuplicate"], imported
    duplicate = import_pdf(first_pdf)
    assert duplicate["source"]["id"] == imported["source"]["id"] and duplicate["isDuplicate"], duplicate
    source_id = imported["source"]["id"]
    other_id = import_pdf(second_pdf)["source"]["id"]
    assert source_id != other_id

    process = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        client = Client(process)
        process.stdin.write(b"{malformed-JSON}\n")
        process.stdin.flush()
        assert client.response()["error"]["code"] == -32700
        assert client.request("tools/list")["error"]["code"] == -32002
        hello = client.request("initialize", {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "cv-vault-smoke-test", "version": "1"},
        })
        assert hello["result"]["protocolVersion"] == "2025-06-18", hello
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert client.request("ping")["result"] == {}
        assert client.request("unrecognized")["error"]["code"] == -32601
        assert client.request("tools/call", {"name": "unrecognized"})["error"]["code"] == -32602

        catalog = client.request("tools/list")["result"]["tools"]
        tools = {tool["name"]: tool for tool in catalog}
        assert tools.keys() == {
            "list_sources", "get_source", "search_facts", "get_fact_structure", "list_cv_styles", "generate_cv"
        }
        assert tools["get_fact_structure"]["inputSchema"]["required"] == ["source_id"]
        selection = tools["generate_cv"]["inputSchema"]["properties"]["template"]
        assert set(selection["enum"]) == set(STYLES), selection
        assert selection["default"] == "source", selection
        assert client.tool("list_cv_styles")["default_style"] == "source"
        for language in ("fr", "en"):
            listing = client.tool("list_cv_styles", language=language)
            styles = listing["styles"]
            assert len(styles) == len(STYLES) and {style["id"] for style in styles} == set(STYLES), listing
            assert all(style["name"].strip() and style["description"].strip() for style in styles), listing
            assert listing["default_style"] == "source", listing
            assert [style["id"] for style in styles if style["default"]] == ["source"], listing
        client.tool("list_cv_styles", language="unsupported", error="language")
        first = client.tool("list_sources", limit=1)
        second = client.tool("list_sources", limit=1, offset=first["next_offset"])
        assert {first["sources"][0]["id"], second["sources"][0]["id"]} == {source_id, other_id}
        assert "next_offset" not in second
        client.tool("list_sources", limit=True, error="integer")
        client.tool("list_sources", typo=2, error="unexpected arguments")

        first_page = client.tool("get_source", source_id=source_id)
        assert len(first_page["pages"]) == 1 and first_page["next_page"] == 2
        assert first_page["pages"][0]["method"] == "text"
        assert "https://example.invalid/portfolio" in first_page["pages"][0]["links"]
        last_page = client.tool("get_source", source_id=source_id, start_page=2)
        assert "Example University" in last_page["pages"][0]["text"]
        assert "next_page" not in last_page

        assert client.tool("search_facts", source_id=source_id)["facts"] == []
        found = client.tool("search_facts", source_id=source_id, category="experience",
                            query="engineers", status="pending")["facts"]
        experience = found[0]
        assert len(found) == 1 and experience["page"] == 1 and experience["sourceID"] == source_id
        assert experience["evidence"] == "- " + experience["text"], experience
        identity = client.tool("search_facts", source_id=source_id, category="identity", status="all")["facts"][0]
        skills = client.tool("search_facts", source_id=source_id, category="skills", status="all")["facts"][0]
        role = client.tool("search_facts", source_id=source_id, category="experience",
                           query="Example Studio", status="all")["facts"][0]
        dates = client.tool("search_facts", source_id=source_id, category="experience",
                            query="2021", status="all")["facts"][0]
        other = client.tool("search_facts", source_id=other_id, category="identity", status="all")["facts"][0]

        structure = client.tool("get_fact_structure", source_id=source_id)
        raw_facts = client.tool("search_facts", source_id=source_id, status="all")["facts"]
        structured_facts = [field["fact"] for entry in structure["entries"] for field in entry["fields"]]
        assert structure["source_id"] == source_id and structure["fact_count"] == len(raw_facts)
        assert structure["entry_count"] == len(structure["entries"]) and "next_offset" not in structure
        assert len({entry["id"] for entry in structure["entries"]}) == structure["entry_count"]
        assert sorted(structured_facts, key=lambda fact: fact["id"]) == sorted(raw_facts, key=lambda fact: fact["id"])
        assert all(entry["sourceID"] == source_id for entry in structure["entries"])

        work = client.tool("get_fact_structure", source_id=source_id, category="experience")
        assert work["entry_count"] == 1 and work["fact_count"] == 3, work
        assert work["entries"][0]["category"] == "experience"
        fields = work["entries"][0]["fields"]
        assert [(field["role"], field["fact"]["id"]) for field in fields] == [
            ("title", role["id"]), ("date", dates["id"]), ("achievement", experience["id"])
        ], fields
        first_entry = client.tool("get_fact_structure", source_id=source_id, limit=1)
        assert first_entry["entries"] == structure["entries"][:1] and first_entry["next_offset"] == 1
        next_entry = client.tool("get_fact_structure", source_id=source_id, limit=1, offset=first_entry["next_offset"])
        assert next_entry["entries"] == structure["entries"][1:2]
        assert next_entry["entry_count"] == structure["entry_count"] and next_entry["fact_count"] == structure["fact_count"]
        end = client.tool("get_fact_structure", source_id=source_id, offset=structure["entry_count"])
        assert end["entries"] == [] and "next_offset" not in end
        client.tool("get_fact_structure", source_id="absent", error="source")
        client.tool("get_fact_structure", source_id=source_id, category="absent", error="category")
        client.tool("get_fact_structure", source_id=source_id, status="absent", error="status")
        client.tool("get_fact_structure", source_id=source_id, limit=51, error="limit")

        visible_ids = [identity["id"], skills["id"], experience["id"]]
        client.tool("generate_cv", fact_ids=visible_ids, error="verified")
        verify_fixture_facts(vault, [experience["id"]])
        verified_work = client.tool("get_fact_structure", source_id=source_id, category="experience", status="verified")
        assert verified_work["entry_count"] == verified_work["fact_count"] == 1
        assert verified_work["entries"][0]["id"] == work["entries"][0]["id"]
        approved_fields = verified_work["entries"][0]["fields"]
        assert len(approved_fields) == 1 and approved_fields[0]["role"] == "achievement"
        assert approved_fields[0]["fact"]["id"] == experience["id"]
        assert approved_fields[0]["fact"]["status"] == "verified"
        verify_fixture_facts(vault, visible_ids + [role["id"], dates["id"], other["id"]])
        assert client.tool("search_facts", source_id=source_id, query="SWIFT")["facts"][0]["status"] == "verified"
        client.tool("generate_cv", fact_ids=[identity["id"], other["id"]], error="single")
        client.tool("generate_cv", fact_ids=[identity["id"], identity["id"]], error="distinct")

        arguments = {
            "fact_ids": visible_ids,
            "language": "en",
            "title": "Platform Engineer",
            "section_labels": {"experience": "Selected work"},
        }
        preview = client.tool("generate_cv", **arguments, template="editorial")
        assert "path" not in preview and not (vault / "Exports").exists(), preview
        assert preview["source_id"] == source_id and preview["fact_ids"] == visible_ids
        assert preview["typst"].index("Swift, SQLite, Typst") < preview["typst"].index("Selected work")
        assert preview["template"] == "editorial" and preview["paper"] == "a4"
        source_preview = client.tool("generate_cv", **arguments)
        assert source_preview["template"] == "source" and source_preview["paper"] == "source"
        assert source_preview["fact_ids"] == visible_ids and source_preview["source_id"] == source_id
        assert client.tool("generate_cv", **arguments, template="source") == source_preview
        assert source_preview["typst"] != preview["typst"]
        source_override = client.tool("generate_cv", **arguments, paper="a4")
        assert (source_override["template"], source_override["paper"]) == ("source", "a4")
        assert source_override["typst"] != source_preview["typst"]

        client.tool("generate_cv", **arguments, filename="../escape.typ", error="file name")
        assert not (vault / "escape.typ").exists()
        saved = client.tool("generate_cv", **arguments, filename="smoke.typ")
        path = Path(saved["path"])
        assert path == vault / "Exports" / "smoke.typ"
        assert path.read_text() == source_preview["typst"] and path.stat().st_mode & 0o777 == 0o600
        client.tool("generate_cv", **arguments, filename="smoke.typ", error="already exists")
        assert path.read_text() == source_preview["typst"]

        grouped_arguments = {
            "fact_ids": [identity["id"], skills["id"], role["id"], dates["id"], experience["id"]],
            "language": "en",
            "template": "classic",
            "paper": "letter",
            "sections": [
                {"category": "experience", "entries": [{
                    "heading_fact_id": role["id"], "metadata_fact_ids": [dates["id"]],
                    "bullet_fact_ids": [experience["id"]],
                }]},
                {"category": "skills", "fact_ids": [skills["id"]]},
            ],
        }
        grouped = client.tool("generate_cv", **grouped_arguments, filename="structured.typ")
        assert grouped["template"] == "classic" and grouped["paper"] == "letter"
        assert grouped["typst"].index("Platform Engineer | Example Studio") < grouped["typst"].index("2021 - 2024")
        assert grouped["typst"].index("2021 - 2024") < grouped["typst"].index("with 3 engineers")
        assert grouped["typst"].index("with 3 engineers") < grouped["typst"].index("Swift, SQLite, Typst")
        client.tool("generate_cv", **{**grouped_arguments, "template": "garish"}, error="template")
        client.tool("generate_cv", **{**grouped_arguments, "sections": [
            {"category": "experience", "fact_ids": [other["id"]]},
        ]}, error="top-level fact_ids")
        client.tool("generate_cv", **{**grouped_arguments, "sections": [
            {"category": "experience", "fact_ids": [role["id"]], "entries": [
                {"heading_fact_id": role["id"]},
            ]},
        ]}, error="only once")
        client.tool("generate_cv", **{**grouped_arguments, "sections": [
            {"category": "skills", "fact_ids": [role["id"]]},
        ]}, error="same category")
        client.tool("generate_cv", **{**grouped_arguments, "sections": [
            {"category": "skills", "fact_ids": [skills["id"]]},
        ]}, error="every selected fact")

        layouts = set()
        sources = [path]
        for style in STYLES:
            result = grouped if style == "classic" else client.tool(
                "generate_cv", **{**grouped_arguments, "template": style}, filename=f"style-{style}.typ"
            )
            assert (result["template"], result["paper"]) == (style, "letter")
            assert result["fact_ids"] == grouped_arguments["fact_ids"] and result["source_id"] == source_id
            phrases = ("Platform Engineer | Example Studio", "with 3 engineers", "Swift, SQLite, Typst")
            assert all(phrase in result["typst"] for phrase in phrases)
            # A style name in a source comment alone does not count as a different layout.
            layout = "\n".join(line for line in result["typst"].splitlines() if not line.lstrip().startswith("//"))
            layouts.add(layout)
            sources.append(Path(result["path"]))
        assert len(layouts) == len(STYLES)

        if typst := shutil.which("typst"):
            pdftotext = shutil.which("pdftotext")
            for source in sources:
                compiled = temp / f"{source.stem}.pdf"
                result = subprocess.run(
                    [typst, "compile", "--ignore-system-fonts", str(source), str(compiled)],
                    timeout=20, capture_output=True, text=True
                )
                assert result.returncode == 0, result.stderr
                assert compiled.read_bytes().startswith(b"%PDF")
                if source == path and (pdfinfo := shutil.which("pdfinfo")):
                    info = subprocess.check_output([pdfinfo, str(compiled)], text=True, timeout=10)
                    size = next(line for line in info.splitlines() if line.startswith("Page size:")).split()
                    assert float(size[2]) == 612 and float(size[4]) == 792, info
                if pdftotext:
                    document = subprocess.check_output([pdftotext, str(compiled), "-"], text=True, timeout=10)
                    text = " ".join(document.split())
                    assert "Alex Example" in text and "with 3 engineers" in text
        else:
            print("Typst executable unavailable. Skipped compiling the generated test CV.")

        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert process.stdout.read() == b"", "Unexpected output after the last MCP response"
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", type=Path, default=Path(".build/debug/cv-vault-mcp"))
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="cv-vault-mcp-") as directory:
        run(binary, Path(directory))
    print("PDF → SQLite → MCP → Typst smoke test passed.")
