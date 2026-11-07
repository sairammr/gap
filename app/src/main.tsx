import { StrictMode, lazy, Suspense, useEffect, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { PrivyProvider } from '@privy-io/react-auth'
import { WagmiProvider } from '@privy-io/wagmi'
import { baseSepolia } from 'wagmi/chains'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import './ui'
import App from './App.tsx'
import { wagmiConfig } from './lib/wagmi.ts'

// #kit opens the UI-kit board, #pitch the deck. Both are full-bleed surfaces
// that replace the desk rather than render inside it, so they branch here
// instead of inside App's view switch. One hash check beats pulling in a router.
const Kit = lazy(() => import('./pages/Kit.tsx'))
const Pitch = lazy(() => import('./pages/Pitch.tsx'))

function Root() {
  const [hash, setHash] = useState(() => location.hash)
  useEffect(() => {
    const onHash = () => setHash(location.hash)
    addEventListener('hashchange', onHash)
    return () => removeEventListener('hashchange', onHash)
  }, [])
  if (hash === '#kit') {
    return (
      <Suspense fallback={null}>
        <Kit />
      </Suspense>
    )
  }
  if (hash === '#pitch') {
    return (
      <Suspense fallback={null}>
        <Pitch />
      </Suspense>
    )
  }
  return <App />
}

const queryClient = new QueryClient()

// The Privy APP ID is a public client credential — it ships in the bundle by
// design. The Privy APP SECRET is server-side only and must never appear here.
const PRIVY_APP_ID = import.meta.env.VITE_PRIVY_APP_ID || 'cmw52dk9i03lm0gjsgf2qy053'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <PrivyProvider
      appId={PRIVY_APP_ID}
      config={{
        defaultChain: baseSepolia,
        supportedChains: [baseSepolia],
        // External wallets, plus an embedded wallet for visitors with none.
        loginMethods: ['wallet', 'email'],
        embeddedWallets: { ethereum: { createOnLogin: 'users-without-wallets' } },
        appearance: { theme: 'dark', accentColor: '#7b61ff', walletChainType: 'ethereum-only' },
      }}
    >
      <QueryClientProvider client={queryClient}>
        <WagmiProvider config={wagmiConfig}>
          <Root />
        </WagmiProvider>
      </QueryClientProvider>
    </PrivyProvider>
  </StrictMode>,
)
