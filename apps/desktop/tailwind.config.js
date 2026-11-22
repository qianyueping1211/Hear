/** @type {import('tailwindcss').Config} */
export default {
  content: ["./index.html", "./subtitle.html", "./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        surface: {
          950: "#0b0f17",
          900: "#111827",
          800: "#1a2333",
          700: "#243044",
        },
        brand: {
          400: "#60a5fa",
          500: "#3b82f6",
          600: "#2563eb",
        },
      },
    },
  },
  plugins: [],
};
