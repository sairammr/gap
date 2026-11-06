// Standalone entry for the UI-kit board: /kit.html.
// The kit is pure presentation, so it mounts with no wallet or query providers —
// which also means it stays reviewable when the app's auth stack is mid-change.
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './ui'
import Kit from './pages/Kit.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Kit />
  </StrictMode>,
)
