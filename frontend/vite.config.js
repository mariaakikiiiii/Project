import { defineConfig } from 'vite';
export default defineConfig({server:{proxy:{'/api':{
  target:'https://localhost:7043', secure:true
}}}});
