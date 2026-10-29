// The account a session was bound to at its real start. Held in `$.state`, which survives a
// reload of this module inside the same session (module variables do not).
export type BalanceBarModSession = {
  status: "bound" | "untrusted"
  emailHash: string | null
  organizationHash: string | null
}

declare module "claude-code" {
  interface PluginState {
    "balancebar-mod": { session: BalanceBarModSession }
  }
}
