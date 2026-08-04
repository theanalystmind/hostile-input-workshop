# Hostile Input :: Pre-Workshop Setup and QA

**PDF Triage That Survives an Adversarial Document**
DEF CON 34, Malware Village. The Analyst Mind.

Read this before the con. The setup pulls a 9.6GB model.

The workshop is hands-on. If your environment is not green when you sit down, you will spend the load-bearing block debugging instead of building. The QA smoke test at the end of this doc is the gate. Run it. Get all green. Then you are ready.

---

## What you need

- A laptop with **16GB RAM minimum**.
- **~30GB free disk** for the VM: Kali plus a 9.6GB model plus working room.
- A hypervisor. VirtualBox or VMware on Intel/AMD, UTM / Parallels etc. on Apple Silicon.
- No hypervisor? You can run the PDF tools directly on your machine — see the note below.
- A reliable network for the one-time downloads.

Everything runs **inside your own system**. Nothing leaves it. That is not incidental, it is the point
of the workshop.

### How the two halves fit together

Read this before you start, because it decides how you set everything up.

- **The PDF tools run in the VM.** `file`, `pdfid`, `pdf-parser`, `pdftotext`, `qpdf`. The hostile
  samples stay in there and never touch your host filesystem.
- **The model runs natively on your host.** Not in the VM. Inference inside a virtual machine is slow
  enough to ruin the workshop.

The scripts in the VM call the model API on your host across the VM boundary. That link is the single
most likely thing to be broken when you sit down, which is why the smoke test in Step 5 checks it
explicitly.

**If you would rather not run a VM at all,** you can install the PDF tools directly on your machine and
run everything in one place. The samples in this workshop are inert and fictional by construction, and
none of these tools execute anything they parse.

---

## Step 1: Build your Kali VM

Pick the branch that matches your hardware. This is the only place the two paths diverge.

### Intel / AMD host (Windows, Linux, Intel Mac)

1. Download the official Kali VirtualBox or VMware image from `https://www.kali.org/get-kali/#kali-virtual-machines`.
2. Import it into your hypervisor.
3. Allocate at least **4GB RAM** and **30GB disk** to the VM. The model runs on the host, not in
   the VM, so the VM stays light — leave the rest of your RAM free for the 9.6GB model.

### Apple Silicon host (M1, M2, M3, M4)

Do **not** download the x86 image and emulate it. Emulated inference is unusably slow for this workshop. Stay native.

1. Install a hypervisor like UTM from `https://mac.getutm.app`.
2. Download the **Kali ARM64 installer image** and follow the Kali/UTM walkthrough at `https://www.kali.org/docs/virtualization/`.
3. Allocate at least **4GB RAM** and **30GB disk**.

---

## Step 2: Install the PDF triage tools

Inside the Kali VM:

```bash
sudo apt update
sudo apt install -y pdfid pdf-parser poppler-utils qpdf file jq curl
```

That gives you the full kit:

| Tool | Job in the workshop |
|---|---|
| `file` | First-pass type identification |
| `pdfid` | Structural triage, suspicious keyword surface |
| `pdf-parser` | Object and stream parsing, embedded-file extraction |
| `pdftotext` | Text extraction, one side of the parser differential |
| `qpdf` | Reads what the page *draws* — the other side of the glyph differential |
| `pdffonts` | Says whether a font carries a `/ToUnicode` map, which is what guards that check (ships in `poppler-utils`) |
| `jq` | Parses the model advisor's JSON reply in `triage.sh` |
| `curl` | Calls the local Ollama API from the triage scripts |

---

## Step 3: Install Ollama and pull the model — ON THE HOST

**This step happens on your host machine, not in the VM.** On macOS or Windows use the installer from
`https://ollama.com/download`. On Linux:

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull gemma4:e4b
```

The pull is ~9.6GB. It runs once, on your home network. Verify it landed:

```bash
ollama list
```

You should see `gemma4:e4b`. If the pull dies partway, run it again. Ollama resumes.

### Let the VM reach it

By default Ollama listens on `localhost` only, so your VM cannot see it. This is the number one setup
failure. Bind it to all interfaces:

```bash
# macOS
launchctl setenv OLLAMA_HOST "0.0.0.0:11434"
# then quit Ollama from the menu bar and start it again

# Linux
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

Then allow inbound port `11434` through your host firewall. On macOS, System Settings has to be told to
allow incoming connections for Ollama the first time.

Find the address the VM should use. From inside the VM:

```bash
ip route | awk '/^default/{print $3}'
```

That is usually `10.0.2.2` on VirtualBox NAT and `192.168.64.1` on UTM shared networking. The smoke test
in Step 5 tries all of these automatically and tells you which one worked, so you do not have to guess.

### Context length — do not skip this

Ollama defaults to a 4096-token context and **truncates silently** when you exceed it. No error, no
warning, just a model that never saw the end of your document. In a workshop about a hidden instruction
buried in a PDF, silent truncation is the difference between a demo that works and one that mysteriously
does not.

`triage.sh` already pins `num_ctx: 16384` per request, so the load-bearing script is safe on its own.
If you want the larger context to be the default for everything, set it on the host:

```bash
# macOS
launchctl setenv OLLAMA_CONTEXT_LENGTH "16384"
# Linux
OLLAMA_CONTEXT_LENGTH=16384 ollama serve
```

Be aware this costs RAM on top of the 9.6GB model. On a 16GB machine, close other applications first. If
the model starts refusing to load or the host begins swapping, drop back.

### Apple Silicon

Ollama on macOS already uses Metal GPU acceleration natively, so a standard `ollama pull gemma4:e4b` is
fast on M-series hardware. That is the supported path and it is what these scripts are written against.

An MLX-optimised build is faster still on Apple Silicon, and Ollama serves these under an `-mlx` tag.
Pull it, then **alias it to the workshop's default name**:

```bash
ollama pull gemma4:e4b-mlx
ollama cp gemma4:e4b-mlx gemma4:e4b
```

That second line matters more than it looks. Every script, every exercise card on the projector, and
every line in the labs says `gemma4:e4b`. The alias costs no extra disk — Ollama points a second name
at the same blob — and it means Intel, AMD and Apple attendees run identical commands and share one
`config.env`.

Because it is still Ollama serving it, the API is unchanged and every script here works as written.

> One thing to avoid: if you bypass Ollama and run a standalone MLX server such as `mlx_lm.server`, or
> LM Studio's server, those speak an OpenAI-compatible API at `/v1/chat/completions` rather than Ollama's
> `/api/chat` and `/api/generate`. Every script in this repo calls the Ollama endpoints, so a standalone
> MLX server will not work with them unmodified. Pull the `-mlx` tag through Ollama instead.

### If 16GB is tight

A smaller build works. Verified against every workshop sample, including the
two look-alike CTF files that are hardest to tell apart — it separated them correctly.

```bash
ollama pull gemma4:e2b
ollama pull gemma4:e2b-mlx          # Apple Silicon only
ollama cp   gemma4:e2b-mlx gemma4:e4b
```

~6.5GB instead of ~9.6GB, and the alias means you still run the same commands as everyone
else.

The smaller build sits closer to the edge: in testing, one of its answers arrived with stray text before the JSON and only parsed because
the script anchors on the key name. If your machine can run `gemma4:e4b`, run `gemma4:e4b`.

---

## Step 4: Get the QA kit

Three small files, fetched straight from this repository. Inside the VM:

```bash
mkdir -p ~/hostile-input/samples && cd ~/hostile-input
wget https://raw.githubusercontent.com/theanalystmind/hostile-input-workshop/main/smoke.sh
wget https://raw.githubusercontent.com/theanalystmind/hostile-input-workshop/main/config.env
wget -P samples https://raw.githubusercontent.com/theanalystmind/hostile-input-workshop/main/samples/smoke.pdf
chmod +x smoke.sh
```

You should now have:

```
~/hostile-input/
  smoke.sh           the QA gate, Step 5
  samples/smoke.pdf  an inert control document
  config.env         where you set your model host
```

`~/hostile-input` is the directory name the workshop assumes throughout — keep it.

---

## Step 5: Run the QA smoke test

This is the gate. `smoke.sh` arrived in Step 4, so there is nothing to copy or paste. Run it. All
green means ready.

```bash
cd ~/hostile-input
chmod +x smoke.sh
./smoke.sh
```

Read `smoke.sh` before you run it if you like. It is short, and it does exactly two things: checks the
tools here, then checks that the model API on your host answers.

A green run looks like this. Your API address will differ depending on your hypervisor.

```
== Tool presence (these run HERE) ==
[ PASS ] file present
[ PASS ] pdfid present
[ PASS ] pdf-parser present
[ PASS ] pdftotext present
[ PASS ] pdfinfo present
[ PASS ] pdffonts present
[ PASS ] qpdf present
[ PASS ] jq present
[ PASS ] curl present

== Sample set ==
[ PASS ] smoke sample present

== Tools run against sample ==
[ PASS ] file reads sample
[ PASS ] pdfid reads sample
[ PASS ] pdf-parser reads sample
[ PASS ] pdftotext reads sample
[ PASS ] qpdf reads sample

== Model API (runs on your HOST, reached from here) ==
[ PASS ] model API reachable at http://10.0.2.2:11434
[ PASS ] gemma4:e4b is pulled
[ PASS ] gemma4:e4b answered a live prompt at num_ctx 16384

         Put this in config.env and you never type it again:
           OLLAMA_HOST=http://10.0.2.2:11434

ALL GREEN. You are ready for the workshop.
```

If the model API line says FAIL, the script prints the exact fix. Nine times out of ten it is Ollama still bound to localhost on the host. Go back to Step 3.

---

## Troubleshooting

**The model pull is slow or dies.** You are on a weak network. Move closer to the router, or run `ollama pull gemma4:e4b` again. It resumes, it does not restart.

**`pdfid` or `pdf-parser` not found.** Your Kali build did not carry the apt packages. Use the direct-download block in Step 2 — the tools become `pdfid.py` and `pdf-parser.py`, and the smoke test handles either name.

**Nothing runs at all.** Bring the laptop anyway. There is a buddy path in the room and the handout holds a known-good state at every checkpoint, so you can rejoin at any block.

---

## The one-line checklist

- [ ] Kali VM built on the correct architecture for your hardware
- [ ] `pdfid`, `pdf-parser`, `pdftotext`, `pdfinfo`, `pdffonts`, `file`, `qpdf`, `jq`, `curl` installed
- [ ] `ollama list` on the HOST shows `gemma4:e4b`
- [ ] Ollama on the HOST is bound to `0.0.0.0:11434` and allowed through the firewall
- [ ] `~/hostile-input` holds `smoke.sh`, `config.env` and `samples/smoke.pdf`
- [ ] `./smoke.sh` prints ALL GREEN

Green means you build in the room instead of debugging in it. See you in the village.
