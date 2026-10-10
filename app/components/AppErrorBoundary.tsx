"use client";

import { Component, type ErrorInfo, type ReactNode } from "react";

type Props = { children: ReactNode };
type State = { error: Error | null };

export class AppErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("GIBB Coin UI error", error, info.componentStack);
  }

  render() {
    if (!this.state.error) return this.props.children;
    return (
      <main className="loading-page recovery-page">
        <div className="card card-pad">
          <span className="eyebrow">Wiederherstellung</span>
          <h1>Dieser Bereich konnte nicht geladen werden.</h1>
          <p>Deine serverseitigen Kontodaten bleiben unverändert. Lade die Oberfläche neu, um es erneut zu versuchen.</p>
          <button className="primary" type="button" onClick={() => window.location.reload()}>Oberfläche neu laden</button>
        </div>
      </main>
    );
  }
}
