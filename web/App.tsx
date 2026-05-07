import type { FitAddon } from "@xterm/addon-fit";
import type { Terminal as XTerm } from "@xterm/xterm";
import {
  Keyboard,
  Moon,
  PlugZap,
  RefreshCw,
  RotateCcw,
  Send,
  Settings,
  SquareTerminal,
  Trash2,
  X,
} from "lucide-react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { toast } from "sonner";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import {
  Drawer,
  DrawerClose,
  DrawerContent,
  DrawerDescription,
  DrawerHeader,
  DrawerTitle,
} from "@/components/ui/drawer";
import {
  Empty,
  EmptyDescription,
  EmptyHeader,
  EmptyMedia,
  EmptyTitle,
} from "@/components/ui/empty";
import {
  Field,
  FieldDescription,
  FieldGroup,
  FieldLabel,
} from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Separator } from "@/components/ui/separator";
import {
  Sheet,
  SheetContent,
  SheetDescription,
  SheetFooter,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Textarea } from "@/components/ui/textarea";
import { Toaster } from "@/components/ui/sonner";
import { TooltipProvider } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

type PaneStatus = "running" | "waiting" | "idle" | "failed" | "done";

type Pane = {
  id: string;
  target: string;
  session: string;
  windowIndex: string;
  windowName: string;
  paneIndex: string;
  command: string;
  path: string;
  active: boolean;
  pid: number | null;
  title: string;
  tail: string;
  status: PaneStatus;
  reason: string;
  updatedAt: string;
};

type Snapshot = {
  ok: boolean;
  now: string;
  panes: Pane[];
  error?: string;
};

type ConnectionTone = "ok" | "warn" | "bad" | "";

type WakeLockLike = {
  release(): Promise<void>;
  addEventListener(type: "release", listener: () => void): void;
};

const statusLabels: Record<PaneStatus, string> = {
  running: "Working",
  waiting: "Needs input",
  idle: "Idle",
  failed: "Failed",
  done: "Done",
};

const quickKeys = [
  { label: "Enter", key: "Enter" },
  { label: "Delete", key: "BSpace", vimKey: "VimBackspace" },
  { label: "Clear", key: "C-u", vimKey: "VimClear" },
  { label: "Ctrl-C", key: "C-c" },
  { label: "Ctrl-D", key: "C-d" },
  { label: "Esc", key: "C-[" },
];

const terminalKeyMap: Record<string, string> = {
  Esc: "\x1b",
  Tab: "\t",
  Enter: "\r",
  "⌫": "\x7f",
  "Ctrl-D": "\x04",
  "Ctrl-C": "\x03",
  "Ctrl-U": "\x15",
  Up: "\x1b[A",
  Left: "\x1b[D",
  Down: "\x1b[B",
  Right: "\x1b[C",
};

function initialToken() {
  const token = new URL(location.href).searchParams.get("token") ?? localStorage.getItem("agent-monitor-token") ?? "";
  if (token) localStorage.setItem("agent-monitor-token", token);
  return token;
}

function apiUrl(apiBase: string, path: string) {
  if (!apiBase.trim()) return path;
  return new URL(path, apiBase).toString();
}

function wsUrl(apiBase: string, path: string, params: URLSearchParams) {
  const base = apiBase.trim() || location.origin;
  const url = new URL(path, base);
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
  url.search = params.toString();
  return url.toString();
}

function authQuery(token: string) {
  return token ? `?token=${encodeURIComponent(token)}` : "";
}

function authHeaders(token: string): Record<string, string> {
  return token ? { authorization: `Bearer ${token}` } : {};
}

function isCodingAgentPane(pane: Pane) {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${pane.tail}`.toLowerCase();
  return pane.session.startsWith("cc_")
    || pane.session.startsWith("cx_")
    || haystack.includes("claude")
    || haystack.includes("codex")
    || haystack.includes("gpt-");
}

function agentScopedPanes(panes: Pane[]) {
  const codingPanes = panes.filter(isCodingAgentPane);
  return codingPanes.length > 0 ? codingPanes : panes;
}

function projectName(pane: Pane) {
  const pathParts = pane.path.split("/").filter(Boolean);
  const fromPath = pathParts[pathParts.length - 1];
  if (fromPath) return fromPath;
  const sessionParts = pane.session.split("_");
  if (sessionParts.length >= 2) return sessionParts[1];
  return pane.session;
}

function agentName(pane: Pane) {
  const haystack = `${pane.session}\n${pane.command}\n${pane.title}\n${pane.tail}`.toLowerCase();
  if (pane.session.startsWith("cc_")) return "Claude Code";
  if (pane.session.startsWith("cx_")) return "Codex";
  if (haystack.includes("claude")) return "Claude Code";
  if (haystack.includes("codex") || haystack.includes("gpt-")) return "Codex";
  return pane.command || "Shell";
}

function formatTime(value?: string) {
  const date = value ? new Date(value) : new Date();
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function latestLines(tail: string, count: number) {
  return tail.split("\n").filter(Boolean).slice(-count).join("\n");
}

function statusDotClass(status: PaneStatus) {
  return cn(
    "mt-1 size-2.5 shrink-0 rounded-full",
    status === "running" && "bg-primary",
    status === "waiting" && "bg-ring",
    status === "done" && "bg-muted-foreground",
    status === "failed" && "bg-destructive",
    status === "idle" && "bg-muted-foreground",
  );
}

function sectionPanes(panes: Pane[]) {
  return [
    ["Working", panes.filter((pane) => pane.status === "running" || pane.status === "waiting")],
    ["Done", panes.filter((pane) => pane.status === "done")],
    ["Other", panes.filter((pane) => !["running", "waiting", "done"].includes(pane.status))],
  ] as const;
}

export function App() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [selectedPaneId, setSelectedPaneId] = useState<string | null>(null);
  const [connection, setConnection] = useState<{ text: string; tone: ConnectionTone }>({ text: "connecting", tone: "warn" });
  const [token, setToken] = useState(initialToken);
  const [apiBase, setApiBase] = useState(localStorage.getItem("agent-monitor-api-base") ?? "");
  const [settingsApiBase, setSettingsApiBase] = useState(apiBase);
  const [settingsToken, setSettingsToken] = useState(token);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [wakeLockActive, setWakeLockActive] = useState(false);
  const [vimMode, setVimMode] = useState(localStorage.getItem("agent-monitor-vim-mode") === "1");
  const wakeLockRef = useRef<WakeLockLike | null>(null);

  const loadSnapshot = useCallback(async () => {
    setRefreshing(true);
    try {
      const response = await fetch(apiUrl(apiBase, `/api/snapshot${authQuery(token)}`), {
        headers: authHeaders(token),
      });
      const nextSnapshot = await response.json() as Snapshot;
      setSnapshot(nextSnapshot);
      setConnection({ text: nextSnapshot.ok ? "live" : "tmux", tone: nextSnapshot.ok ? "ok" : "bad" });
    } catch {
      setConnection({ text: "offline", tone: "bad" });
    } finally {
      setRefreshing(false);
    }
  }, [apiBase, token]);

  useEffect(() => {
    let cancelled = false;
    let reconnectTimer: number | undefined;
    let currentWs: WebSocket | null = null;
    const connect = () => {
      const params = new URLSearchParams();
      if (token) params.set("token", token);
      const ws = new WebSocket(wsUrl(apiBase, "/ws", params));
      currentWs = ws;
      ws.addEventListener("open", () => setConnection({ text: "live", tone: "ok" }));
      ws.addEventListener("message", (event) => {
        const message = JSON.parse(event.data);
        if (message.snapshot) setSnapshot(message.snapshot);
      });
      ws.addEventListener("close", () => {
        if (cancelled) return;
        setConnection({ text: "retrying", tone: "warn" });
        reconnectTimer = window.setTimeout(connect, 1500);
      });
      ws.addEventListener("error", () => setConnection({ text: "offline", tone: "bad" }));
    };
    connect();
    loadSnapshot();
    return () => {
      cancelled = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      currentWs?.close();
    };
  }, [apiBase, loadSnapshot, token]);

  useEffect(() => {
    const syncWakeLock = async () => {
      if (document.visibilityState === "visible" && wakeLockActive && !wakeLockRef.current) {
        await requestWakeLock();
      }
    };
    document.addEventListener("visibilitychange", syncWakeLock);
    return () => document.removeEventListener("visibilitychange", syncWakeLock);
  }, [wakeLockActive]);

  const panes = useMemo(() => agentScopedPanes(snapshot?.panes ?? []), [snapshot]);
  const selectedPane = useMemo(
    () => snapshot?.panes.find((pane) => pane.id === selectedPaneId) ?? null,
    [selectedPaneId, snapshot],
  );
  const sections = useMemo(() => sectionPanes(panes).filter(([, items]) => items.length > 0), [panes]);

  async function requestWakeLock() {
    const wakeLockApi = (navigator as Navigator & {
      wakeLock?: { request(type: "screen"): Promise<WakeLockLike> };
    }).wakeLock;
    if (!wakeLockApi) {
      toast.error("Wake lock unavailable");
      return;
    }
    try {
      const lock = await wakeLockApi.request("screen");
      wakeLockRef.current = lock;
      setWakeLockActive(true);
      lock.addEventListener("release", () => {
        wakeLockRef.current = null;
        setWakeLockActive(false);
      });
    } catch {
      toast.error("Wake lock blocked");
    }
  }

  async function toggleWakeLock() {
    if (wakeLockRef.current) {
      await wakeLockRef.current.release();
      wakeLockRef.current = null;
      setWakeLockActive(false);
      return;
    }
    await requestWakeLock();
  }

  function saveSettings() {
    const nextBase = settingsApiBase.trim().replace(/\/+$/, "");
    setApiBase(nextBase);
    setToken(settingsToken.trim());
    localStorage.setItem("agent-monitor-api-base", nextBase);
    if (settingsToken.trim()) {
      localStorage.setItem("agent-monitor-token", settingsToken.trim());
    } else {
      localStorage.removeItem("agent-monitor-token");
    }
    setSettingsOpen(false);
  }

  return (
    <TooltipProvider>
      <main className="mx-auto flex min-h-svh w-full max-w-3xl flex-col gap-3 px-3 pb-[calc(1rem+env(safe-area-inset-bottom))] pt-[calc(0.6rem+env(safe-area-inset-top))]">
        <header className="sticky top-0 z-10 -mx-3 flex items-center justify-between border-b bg-background/95 px-3 py-2 backdrop-blur">
          <Sheet open={settingsOpen} onOpenChange={setSettingsOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon-lg" aria-label="Settings">
                <Settings data-icon="icon-only" />
              </Button>
            </SheetTrigger>
            <SheetContent side="left" className="w-[88vw] max-w-sm">
              <SheetHeader>
                <SheetTitle>Settings</SheetTitle>
                <SheetDescription className="sr-only">Configure the Agent Monitor service endpoint.</SheetDescription>
              </SheetHeader>
              <div className="px-4">
                <FieldGroup>
                  <Field>
                    <FieldLabel htmlFor="service-origin">Service origin</FieldLabel>
                    <Input
                      id="service-origin"
                      inputMode="url"
                      placeholder="http://100.64.0.10:8787"
                      value={settingsApiBase}
                      onChange={(event) => setSettingsApiBase(event.target.value)}
                    />
                    <FieldDescription>Empty uses the current host.</FieldDescription>
                  </Field>
                  <Field>
                    <FieldLabel htmlFor="service-token">Token</FieldLabel>
                    <Input
                      id="service-token"
                      placeholder="optional"
                      value={settingsToken}
                      onChange={(event) => setSettingsToken(event.target.value)}
                    />
                  </Field>
                </FieldGroup>
              </div>
              <SheetFooter>
                <Button onClick={saveSettings}>Save</Button>
              </SheetFooter>
            </SheetContent>
          </Sheet>

          <Badge variant={connection.tone === "bad" ? "destructive" : "secondary"} className="h-8 rounded-lg px-3">
            {connection.text}
            {snapshot?.now ? ` · ${formatTime(snapshot.now)}` : ""}
          </Badge>

          <div className="flex items-center gap-1">
            <Button
              variant={wakeLockActive ? "secondary" : "ghost"}
              size="icon-lg"
              aria-label="Keep awake"
              onClick={toggleWakeLock}
            >
              <Moon data-icon="icon-only" />
            </Button>
            <Button variant="ghost" size="icon-lg" aria-label="Refresh" disabled={refreshing} onClick={loadSnapshot}>
              <RefreshCw data-icon="icon-only" className={cn(refreshing && "animate-spin")} />
            </Button>
          </div>
        </header>

        {!snapshot && <LoadingList />}
        {snapshot && !snapshot.ok && (
          <Empty className="min-h-[55svh]">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <PlugZap />
              </EmptyMedia>
              <EmptyTitle>tmux unavailable</EmptyTitle>
              <EmptyDescription>{snapshot.error ?? "No data"}</EmptyDescription>
            </EmptyHeader>
          </Empty>
        )}
        {snapshot?.ok && panes.length === 0 && (
          <Empty className="min-h-[55svh]">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <SquareTerminal />
              </EmptyMedia>
              <EmptyTitle>No sessions</EmptyTitle>
              <EmptyDescription>Start Claude Code or Codex inside tmux.</EmptyDescription>
            </EmptyHeader>
          </Empty>
        )}
        {snapshot?.ok && panes.length > 0 && (
          <div className="flex flex-col gap-5">
            {sections.map(([title, items]) => (
              <section key={title} className="flex flex-col gap-2">
                <div className="flex items-center justify-between px-1">
                  <h2 className="text-sm font-medium text-muted-foreground">{title}</h2>
                  <Badge variant="outline">{items.length}</Badge>
                </div>
                <div className="flex flex-col gap-2">
                  {items.map((pane) => (
                    <PaneCard key={pane.id} pane={pane} onOpen={() => setSelectedPaneId(pane.id)} />
                  ))}
                </div>
              </section>
            ))}
          </div>
        )}

        <PaneDrawer
          apiBase={apiBase}
          token={token}
          pane={selectedPane}
          open={Boolean(selectedPane)}
          vimMode={vimMode}
          onOpenChange={(open) => {
            if (!open) setSelectedPaneId(null);
          }}
          onRefresh={loadSnapshot}
          onVimModeChange={(next) => {
            setVimMode(next);
            localStorage.setItem("agent-monitor-vim-mode", next ? "1" : "0");
          }}
        />
      </main>
      <Toaster />
    </TooltipProvider>
  );
}

function LoadingList() {
  return (
    <div className="flex flex-col gap-2 pt-2">
      {[0, 1, 2].map((item) => (
        <Card key={item}>
          <CardHeader>
            <Skeleton className="h-5 w-2/5" />
            <Skeleton className="h-4 w-3/5" />
          </CardHeader>
          <CardContent>
            <Skeleton className="h-20 w-full" />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

function PaneCard({ pane, onOpen }: { pane: Pane; onOpen(): void }) {
  const last = latestLines(pane.tail, 5) || pane.path || "No output yet";
  return (
    <Card className="overflow-hidden rounded-lg" role="button" tabIndex={0} onClick={onOpen} onKeyDown={(event) => {
      if (event.key === "Enter" || event.key === " ") onOpen();
    }}>
      <CardHeader className="pb-2">
        <div className="flex min-w-0 items-start gap-3">
          <span className={statusDotClass(pane.status)} />
          <div className="min-w-0 flex-1">
            <div className="flex min-w-0 items-center justify-between gap-2">
              <CardTitle className="truncate text-lg">{projectName(pane)}</CardTitle>
              <Badge variant={pane.status === "failed" ? "destructive" : "secondary"}>{statusLabels[pane.status]}</Badge>
            </div>
            <CardDescription className="mt-1 flex min-w-0 items-center gap-2">
              <span className="truncate">{agentName(pane)}</span>
              <span className="text-muted-foreground">/</span>
              <span className="truncate">{pane.session}</span>
            </CardDescription>
          </div>
        </div>
      </CardHeader>
      <CardContent>
        <pre className="max-h-28 overflow-hidden rounded-md bg-terminal p-3 font-mono text-[12px] leading-5 text-muted-foreground whitespace-pre-wrap">
          {last}
        </pre>
      </CardContent>
    </Card>
  );
}

function PaneDrawer({
  apiBase,
  token,
  pane,
  open,
  vimMode,
  onOpenChange,
  onRefresh,
  onVimModeChange,
}: {
  apiBase: string;
  token: string;
  pane: Pane | null;
  open: boolean;
  vimMode: boolean;
  onOpenChange(open: boolean): void;
  onRefresh(): Promise<void>;
  onVimModeChange(next: boolean): void;
}) {
  const [tab, setTab] = useState("actions");
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [killing, setKilling] = useState(false);
  const actionsEndRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (open) setTab("actions");
  }, [open, pane?.id]);

  useLayoutEffect(() => {
    if (!open || tab !== "actions") return;
    const frame = requestAnimationFrame(() => {
      actionsEndRef.current?.scrollIntoView({ block: "end" });
    });
    return () => cancelAnimationFrame(frame);
  }, [open, pane?.id, pane?.tail, tab]);

  if (!pane) return null;

  async function sendText() {
    if (!pane || !text.trim()) return;
    setSending(true);
    try {
      const response = await fetch(apiUrl(apiBase, "/api/send"), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...authHeaders(token),
        },
        body: JSON.stringify({ paneId: pane.id, text, enter: true, vimMode }),
      });
      if (!response.ok) throw new Error("send failed");
      setText("");
      await onRefresh();
    } catch {
      toast.error("Send failed");
    } finally {
      setSending(false);
    }
  }

  async function sendKey(key: string) {
    if (!pane) return;
    try {
      const response = await fetch(apiUrl(apiBase, `/api/key?paneId=${encodeURIComponent(pane.id)}&key=${encodeURIComponent(key)}`), {
        method: "POST",
        headers: authHeaders(token),
      });
      if (!response.ok) throw new Error("key failed");
      await onRefresh();
    } catch {
      toast.error("Key failed");
    }
  }

  async function killSession() {
    if (!pane) return;
    setKilling(true);
    try {
      const response = await fetch(apiUrl(apiBase, "/api/session/kill"), {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...authHeaders(token),
        },
        body: JSON.stringify({ session: pane.session }),
      });
      if (!response.ok) throw new Error("kill failed");
      onOpenChange(false);
      await onRefresh();
    } catch {
      toast.error("Kill failed");
    } finally {
      setKilling(false);
    }
  }

  return (
    <Drawer open={open} onOpenChange={onOpenChange}>
      <DrawerContent className="h-dvh max-h-dvh rounded-none data-[vaul-drawer-direction=bottom]:mt-0 data-[vaul-drawer-direction=bottom]:h-dvh data-[vaul-drawer-direction=bottom]:max-h-dvh data-[vaul-drawer-direction=bottom]:rounded-none">
        <DrawerHeader className="px-3 pb-2 text-left">
          <div className="flex min-w-0 items-start justify-between gap-2">
            <div className="min-w-0">
              <DrawerTitle className="truncate">{projectName(pane)}</DrawerTitle>
              <DrawerDescription className="truncate">
                {agentName(pane)} · {pane.session}
              </DrawerDescription>
            </div>
            <DrawerClose asChild>
              <Button variant="ghost" size="icon-sm" aria-label="Close">
                <X data-icon="icon-only" />
              </Button>
            </DrawerClose>
          </div>
        </DrawerHeader>
        <Tabs value={tab} onValueChange={setTab} className="min-h-0 flex-1 gap-0">
          <div className="border-y px-3 py-2">
            <TabsList className="grid w-full grid-cols-3">
              <TabsTrigger value="actions">Actions</TabsTrigger>
              <TabsTrigger value="terminal">Terminal</TabsTrigger>
              <TabsTrigger value="meta">Meta</TabsTrigger>
            </TabsList>
          </div>
          <TabsContent value="actions" className="min-h-0 flex-1 overflow-hidden p-0">
            <div className="flex h-full flex-col gap-3 p-3">
              <ScrollArea className="min-h-0 flex-1 rounded-md border bg-terminal">
                <pre className="p-3 font-mono text-[12px] leading-5 text-muted-foreground whitespace-pre-wrap">
                  {pane.tail || "No output yet"}
                </pre>
                <div ref={actionsEndRef} />
              </ScrollArea>
              <div className="-mx-3 flex gap-2 overflow-x-auto px-3 pb-1">
                {quickKeys.map((item) => (
                  <Button
                    key={item.label}
                    variant="outline"
                    className="shrink-0"
                    onClick={() => sendKey(vimMode && item.vimKey ? item.vimKey : item.key)}
                  >
                    {item.label}
                  </Button>
                ))}
              </div>
              <Field orientation="horizontal" className="items-center justify-between">
                <FieldLabel htmlFor="vim-mode">Vim mode</FieldLabel>
                <Switch id="vim-mode" checked={vimMode} onCheckedChange={onVimModeChange} />
              </Field>
              <div className="flex gap-2">
                <Textarea
                  value={text}
                  onChange={(event) => setText(event.target.value)}
                  placeholder="Reply"
                  className="min-h-20 resize-none text-base"
                />
                <div className="flex shrink-0 flex-col gap-2">
                  <Button variant="outline" size="icon-lg" aria-label="Clear input" onClick={() => setText("")}>
                    <Trash2 data-icon="icon-only" />
                  </Button>
                  <Button size="icon-lg" aria-label="Send" disabled={sending || !text.trim()} onClick={sendText}>
                    <Send data-icon="icon-only" />
                  </Button>
                </div>
              </div>
              <Separator />
              <AlertDialog>
                <AlertDialogTrigger asChild>
                  <Button variant="destructive" disabled={killing}>
                    <Trash2 data-icon="inline-start" />
                    Kill session
                  </Button>
                </AlertDialogTrigger>
                <AlertDialogContent>
                  <AlertDialogHeader>
                    <AlertDialogTitle>Kill tmux session?</AlertDialogTitle>
                    <AlertDialogDescription>{pane.session} will be closed.</AlertDialogDescription>
                  </AlertDialogHeader>
                  <AlertDialogFooter>
                    <AlertDialogCancel>Cancel</AlertDialogCancel>
                    <AlertDialogAction variant="destructive" onClick={killSession}>Kill</AlertDialogAction>
                  </AlertDialogFooter>
                </AlertDialogContent>
              </AlertDialog>
            </div>
          </TabsContent>
          <TabsContent value="terminal" className="min-h-0 flex-1 overflow-hidden p-0">
            <TerminalPanel apiBase={apiBase} token={token} pane={pane} active={tab === "terminal"} />
          </TabsContent>
          <TabsContent value="meta" className="p-3">
            <dl className="grid grid-cols-1 gap-2 text-sm">
              {[
                ["Status", statusLabels[pane.status]],
                ["Path", pane.path],
                ["Target", pane.target],
                ["Pane", pane.id],
                ["PID", pane.pid ?? "-"],
              ].map(([label, value]) => (
                <div key={label} className="rounded-md border p-3">
                  <dt className="text-muted-foreground">{label}</dt>
                  <dd className="mt-1 truncate font-mono">{String(value)}</dd>
                </div>
              ))}
            </dl>
          </TabsContent>
        </Tabs>
      </DrawerContent>
    </Drawer>
  );
}

function TerminalPanel({ apiBase, token, pane, active }: { apiBase: string; token: string; pane: Pane; active: boolean }) {
  const mountRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<XTerm | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  const wsRef = useRef<WebSocket | null>(null);
  const fitFrameRef = useRef<number | null>(null);
  const writeFrameRef = useRef<number | null>(null);
  const pendingOutputRef = useRef("");
  const [state, setState] = useState("offline");
  const [inputEnabled, setInputEnabled] = useState(false);
  const [connectionEpoch, setConnectionEpoch] = useState(0);

  const fitTerminal = useCallback(() => {
    if (!termRef.current || !fitRef.current) return;
    if (fitFrameRef.current) return;
    fitFrameRef.current = requestAnimationFrame(() => {
      fitFrameRef.current = null;
      fitRef.current?.fit();
      if (wsRef.current?.readyState === WebSocket.OPEN && termRef.current) {
        wsRef.current.send(JSON.stringify({
          type: "resize",
          cols: termRef.current.cols,
          rows: termRef.current.rows,
        }));
      }
    });
  }, []);

  const writeTerminal = useCallback((data: string) => {
    pendingOutputRef.current += data;
    if (writeFrameRef.current) return;
    writeFrameRef.current = requestAnimationFrame(() => {
      writeFrameRef.current = null;
      if (!termRef.current || !pendingOutputRef.current) return;
      const chunk = pendingOutputRef.current;
      pendingOutputRef.current = "";
      termRef.current.write(chunk);
    });
  }, []);

  useEffect(() => {
    if (active) setInputEnabled(false);
  }, [active, pane.id]);

  useEffect(() => {
    if (!active || !termRef.current) return;
    termRef.current.options.disableStdin = !inputEnabled;
    if (inputEnabled) {
      termRef.current.focus();
    } else {
      termRef.current.blur();
    }
  }, [active, inputEnabled]);

  useEffect(() => {
    if (!active || !mountRef.current) return;
    setState("connecting");
    setInputEnabled(false);
    let disposed = false;
    let ws: WebSocket | null = null;
    let term: XTerm | null = null;

    Promise.all([import("@xterm/xterm"), import("@xterm/addon-fit")]).then(([xterm, fitAddon]) => {
      if (disposed || !mountRef.current) return;
      const mobile = window.matchMedia("(max-width: 720px)").matches;
      term = new xterm.Terminal({
        cursorBlink: !mobile,
        fontFamily: 'ui-monospace, "SF Mono", Menlo, Monaco, Consolas, monospace',
        fontSize: mobile ? 12 : 13,
        lineHeight: 1.12,
        scrollback: mobile ? 800 : 2500,
        disableStdin: true,
        theme: {
          background: "#050605",
          foreground: "#dce4d3",
          cursor: "#9de07b",
          selectionBackground: "#31402d",
        },
      });
      const fit = new fitAddon.FitAddon();
      term.loadAddon(fit);
      mountRef.current.textContent = "";
      term.open(mountRef.current);
      fit.fit();

      const params = new URLSearchParams({
        token,
        paneId: pane.id,
        cols: String(term.cols),
        rows: String(term.rows),
      });
      ws = new WebSocket(wsUrl(apiBase, "/terminal/ws", params));
      termRef.current = term;
      fitRef.current = fit;
      wsRef.current = ws;

      term.onData((data) => {
        if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "input", data }));
      });
      term.onResize(({ cols, rows }) => {
        if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ type: "resize", cols, rows }));
      });
      ws.addEventListener("open", () => {
        setState("live");
        fitTerminal();
      });
      ws.addEventListener("message", (event) => {
        const message = JSON.parse(event.data);
        if (message.type === "data") writeTerminal(message.data);
        if (message.type === "error") {
          term?.writeln(`\r\n[agent-monitor] ${message.error}`);
          setState("error");
        }
        if (message.type === "exit") setState("closed");
      });
      ws.addEventListener("close", () => setState("closed"));
      ws.addEventListener("error", () => setState("error"));
    }).catch(() => setState("error"));

    window.addEventListener("resize", fitTerminal);
    window.visualViewport?.addEventListener("resize", fitTerminal);

    return () => {
      disposed = true;
      window.removeEventListener("resize", fitTerminal);
      window.visualViewport?.removeEventListener("resize", fitTerminal);
      if (fitFrameRef.current) cancelAnimationFrame(fitFrameRef.current);
      if (writeFrameRef.current) cancelAnimationFrame(writeFrameRef.current);
      ws?.close();
      term?.dispose();
      termRef.current = null;
      fitRef.current = null;
      wsRef.current = null;
      fitFrameRef.current = null;
      writeFrameRef.current = null;
      pendingOutputRef.current = "";
      setState("offline");
    };
  }, [active, apiBase, connectionEpoch, fitTerminal, pane.id, token, writeTerminal]);

  function sendInput(data: string) {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify({ type: "input", data }));
      if (inputEnabled) termRef.current?.focus();
    }
  }

  return (
    <div className="flex h-full min-h-0 flex-col bg-background">
      <div className="flex items-center justify-between gap-2 border-b px-3 py-2">
        <div className="flex min-w-0 items-center gap-2">
          <Badge variant={state === "live" ? "secondary" : "outline"}>{state}</Badge>
          <Badge variant={inputEnabled ? "default" : "outline"}>{inputEnabled ? "typing" : "view"}</Badge>
        </div>
        <div className="flex items-center gap-1">
          <Button
            variant={inputEnabled ? "secondary" : "outline"}
            size="sm"
            onClick={() => setInputEnabled((value) => !value)}
          >
            <Keyboard data-icon="inline-start" />
            {inputEnabled ? "Typing" : "Keyboard"}
          </Button>
          <Button variant="outline" size="icon-sm" aria-label="Reconnect" onClick={() => setConnectionEpoch((value) => value + 1)}>
            <RefreshCw data-icon="icon-only" />
          </Button>
          <Button variant="outline" size="icon-sm" aria-label="Fit terminal" onClick={fitTerminal}>
            <RotateCcw data-icon="icon-only" />
          </Button>
        </div>
      </div>
      <div
        ref={mountRef}
        className="min-h-0 flex-1 overflow-hidden bg-terminal"
        onPointerDownCapture={() => {
          if (!inputEnabled) termRef.current?.blur();
        }}
      />
      <div className="grid grid-cols-4 gap-2 border-t bg-background px-3 py-2 pb-[calc(0.5rem+env(safe-area-inset-bottom))]">
        {Object.keys(terminalKeyMap).map((label) => (
          <Button key={label} variant="outline" onClick={() => sendInput(terminalKeyMap[label])}>
            {label}
          </Button>
        ))}
      </div>
    </div>
  );
}
