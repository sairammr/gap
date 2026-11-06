import { http } from 'wagmi'
import { baseSepolia } from 'wagmi/chains'
import { createConfig } from '@privy-io/wagmi'

// Base Sepolia only. Connectors are NOT declared here: Privy is the connector
// source of truth, so `@privy-io/wagmi`'s createConfig builds the config and
// `@privy-io/wagmi`'s WagmiProvider injects the wallets Privy has connected
// (embedded or external) into wagmi state. Every wagmi hook keeps working.
export const wagmiConfig = createConfig({
  chains: [baseSepolia],
  transports: {
    [baseSepolia.id]: http('https://sepolia.base.org'),
  },
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
