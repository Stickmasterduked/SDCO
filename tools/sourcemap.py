"""Builds a Rojo-style sourcemap.json from src/ so luau-lsp can resolve requires."""
import json, os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SRC = os.path.join(ROOT, "src")


def script_node(path):
    base = os.path.basename(path)
    name = base.split(".")[0]
    cls = "Script" if ".server." in base else "LocalScript" if ".client." in base else "ModuleScript"
    return {"name": name, "className": cls, "filePaths": [os.path.relpath(path, ROOT)]}


def folder(path, name, cls="Folder"):
    children = []
    for entry in sorted(os.listdir(path)):
        full = os.path.join(path, entry)
        if os.path.isdir(full):
            children.append(folder(full, entry))
        elif entry.endswith(".luau"):
            children.append(script_node(full))
    return {"name": name, "className": cls, "children": children}


rs = folder(os.path.join(SRC, "ReplicatedStorage"), "ReplicatedStorage", "ReplicatedStorage")
combat = next(c for c in rs["children"] if c["name"] == "Combat")
combat["children"].append({
    "name": "Remotes", "className": "Folder",
    "children": [{"name": n, "className": "RemoteEvent"} for n in ("Ack", "Action", "Anim", "Effect", "Impulse")],
})
sss = folder(os.path.join(SRC, "ServerScriptService"), "ServerScriptService", "ServerScriptService")
sps = folder(os.path.join(SRC, "StarterPlayerScripts"), "StarterPlayerScripts", "StarterPlayerScripts")
tree = {"name": "Game", "className": "DataModel", "children": [
    rs, sss, {"name": "StarterPlayer", "className": "StarterPlayer", "children": [sps]},
]}
with open(os.path.join(ROOT, "sourcemap.json"), "w") as f:
    json.dump(tree, f, indent=1)
