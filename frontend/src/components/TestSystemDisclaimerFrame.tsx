import { isLocalOrDev } from "@/lib/env";
import type { ReactNode } from "react";

const TEST_SYSTEM_DISCLAIMER_TEXT =
  "TESTSYSTEM: Dies ist ein Testsystem. Daten können jederzeit verloren gehen. Die Verfügbarkeit ist nicht gewährleistet.";

export function TestSystemDisclaimerFrame({ children }: { children: ReactNode }) {
  if (!isLocalOrDev()) {
    return <>{children}</>;
  }

  return (
    <div className="test-system-shell">
      <div className="test-system-frame" aria-hidden="true">
        <div className="test-system-frame__edge test-system-frame__edge--top">
          <span className="test-system-frame__text">{TEST_SYSTEM_DISCLAIMER_TEXT}</span>
        </div>
        <div className="test-system-frame__edge test-system-frame__edge--right" />
        <div className="test-system-frame__edge test-system-frame__edge--bottom" />
        <div className="test-system-frame__edge test-system-frame__edge--left" />
      </div>
      <div className="test-system-shell__content">{children}</div>
    </div>
  );
}
