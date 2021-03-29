import { Container } from "theme-ui";

import { Trove } from "../components/Trove/Trove";
import { Stability } from "../components/Stability/Stability";
import { SystemStats } from "../components/SystemStats";
import { PriceManager } from "../components/PriceManager";
import { TroveViewProvider } from "../components/Trove/context/TroveViewProvider";
import { StabilityViewProvider } from "../components/Stability/context/StabilityViewProvider";
import { Staking } from "../components/Staking/Staking";

export const Dashboard: React.FC = () => (
  <Container variant="columns">
    <Container variant="left">
      <TroveViewProvider>
        <Trove />
      </TroveViewProvider>

      <StabilityViewProvider>
        <Stability />
      </StabilityViewProvider>

      <Staking />
    </Container>

    <Container variant="right">
      <SystemStats />
      <PriceManager />
    </Container>
  </Container>
);
