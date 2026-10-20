"""Builds the Studio install files from src/.

Run:  python3 tools/build.py

Makes (in install/):
  ReplicatedStorage.rbxmx      right-click ReplicatedStorage    > Insert from File
  ServerScriptService.rbxmx    right-click ServerScriptService  > Insert from File
  StarterPlayerScripts.rbxmx   right-click StarterPlayerScripts > Insert from File
  StudioCommand.lua            one-line Command Bar installer (does all three)

File naming (same as Rojo):  X.server.lua = Script, X.client.lua = LocalScript,
X.lua = ModuleScript, folders = Folder.
"""
import os
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
OUT = os.path.join(ROOT, "install")
SERVICES = ["ReplicatedStorage", "ServerScriptService", "StarterPlayerScripts"]


def read_tree(path):
    """Returns a list of (name, class, source, children) for everything in a folder."""
    items = []
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if os.path.isdir(full):
            items.append((entry, "Folder", None, read_tree(full)))
        elif entry.endswith(".lua"):
            if entry.endswith(".server.lua"):
                name, cls = entry[: -len(".server.lua")], "Script"
            elif entry.endswith(".client.lua"):
                name, cls = entry[: -len(".client.lua")], "LocalScript"
            else:
                name, cls = entry[: -len(".lua")], "ModuleScript"
            with open(full, encoding="utf-8") as f:
                items.append((name, cls, f.read(), []))
    return items


def to_xml(items, counter):
    out = []
    for name, cls, source, children in items:
        counter[0] += 1
        out.append(f'<Item class="{cls}" referent="RBX{counter[0]}"><Properties>')
        out.append(f'<string name="Name">{escape(name)}</string>')
        if source is not None:
            assert "]]>" not in source
            out.append(f'<ProtectedString name="Source"><![CDATA[{source}]]></ProtectedString>')
        out.append("</Properties>")
        out.append(to_xml(children, counter))
        out.append("</Item>")
    return "\n".join(out)


def lua_string(text):
    return '"' + (text.replace("\\", "\\\\").replace('"', '\\"').replace("\r", "")
                  .replace("\n", "\\n").replace("\t", "\\t")) + '"'


def to_lua(items, parent_var, counter):
    out = []
    for name, cls, source, children in items:
        counter[0] += 1
        var = f"i{counter[0]}"
        out.append(f'local {var}=Instance.new("{cls}") {var}.Name={lua_string(name)}')
        if source is not None:
            out.append(f"{var}.Source={lua_string(source)}")
        out.append(to_lua(children, var, counter))
        out.append(f"{var}.Parent={parent_var}")
    return " ".join(x for x in out if x)


def main():
    os.makedirs(OUT, exist_ok=True)
    command = ['local SP=game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")']
    counter = [0]
    for service in SERVICES:
        items = read_tree(os.path.join(SRC, service))
        xml = ('<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
               'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
               'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">\n'
               + to_xml(items, [0]) + "\n</roblox>\n")
        with open(os.path.join(OUT, service + ".rbxmx"), "w", encoding="utf-8") as f:
            f.write(xml)

        parent = "SP" if service == "StarterPlayerScripts" else f'game:GetService("{service}")'
        # remove old copies first, so running the installer twice doesn't make duplicates
        for name, _, _, _ in items:
            command.append(f'if {parent}:FindFirstChild("{name}") then {parent}["{name}"]:Destroy() end')
        command.append(to_lua(items, parent, counter))
    command.append('print("Anime game installed! Press PLAY.")')
    with open(os.path.join(OUT, "StudioCommand.lua"), "w", encoding="utf-8") as f:
        f.write(" ".join(command))  # ONE line on purpose: the Command Bar can mangle line breaks
    print("Built install/ files.")


if __name__ == "__main__":
    main()
