import { defineConfig } from 'vite';
// The API address can be overridden (e.g. a second API on a test database): GAMEON_API=https://localhost:7044
export default defineConfig({server:{proxy:{'/api':{
  target: process.env.GAMEON_API || 'https://localhost:7043', secure:true
}}}});
