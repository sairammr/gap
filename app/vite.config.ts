import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  // kit.html is the UI-kit board — a second entry so it builds and serves
  // independently of the app's provider stack.
  build: {
    rollupOptions: {
      input: { main: 'index.html', kit: 'kit.html' },
    },
  },
})
