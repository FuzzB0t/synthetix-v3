import assertBn from '@synthetixio/core-utils/utils/assertions/assert-bignumber';
import assertRevert from '@synthetixio/core-utils/utils/assertions/assert-revert';
import { Contract, ethers, BigNumber } from 'ethers';
import { bootstrap } from '../bootstrap';
import { snapshotCheckpoint } from '../../utils';
import { wei } from '@synthetixio/wei';

const distUtils = {
  getActor: (id: string) => ethers.utils.formatBytes32String(id),
};

const bn = (n: number) => wei(n).toBN();
const hp = wei(1, 27).toBN();

describe('ScalableMapping', () => {
  const { systems, signers, provider } = bootstrap();
  const restore = snapshotCheckpoint(provider);

  let FakeScalableMapping: Contract;

  const actor1 = distUtils.getActor('1');
  const actor2 = distUtils.getActor('2');
  const actor3 = distUtils.getActor('3');

  before('initialize fake distribution', async () => {
    FakeScalableMapping = systems().Core.connect(signers()[0]);
  });

  describe('set()', async () => {
    before(restore);

    describe('actors enter', async () => {
      before('add value', async () => {
        await FakeScalableMapping.ScalableMapping_set(actor1, bn(50));
        await FakeScalableMapping.ScalableMapping_set(actor2, bn(150));
        await FakeScalableMapping.ScalableMapping_set(actor3, bn(250));
      });

      it('has correct actor shares', async () => {
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor1), bn(50));
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor2), bn(150));
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor3), bn(250));
      });

      it('has correct actor values', async () => {
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor1), bn(50));
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor2), bn(150));
        assertBn.equal(await FakeScalableMapping.ScalableMapping_get(actor3), bn(250));
      });

      it('returns proper total value', async () => {
        assertBn.equal(await FakeScalableMapping.ScalableMapping_totalAmount(), bn(450));
      });
    });

    describe('scale()', async () => {
      const addedValue = wei(1000);
      before('distribute value', async () => {
        await FakeScalableMapping.ScalableMapping_scale(addedValue.toBN());
      });

      let totalAmount: BigNumber;

      it('has correct total amount', async () => {
        totalAmount = await FakeScalableMapping.ScalableMapping_totalAmount();
        assertBn.near(totalAmount, bn(1450), 1); // TODO: some missing precision?
      });

      it('has correct actor values', async () => {
        assertBn.equal(
          await FakeScalableMapping.ScalableMapping_get(actor1),
          bn(50).mul(totalAmount).div(bn(450))
        );
        assertBn.equal(
          await FakeScalableMapping.ScalableMapping_get(actor2),
          bn(150).mul(totalAmount).div(bn(450))
        );
        assertBn.equal(
          await FakeScalableMapping.ScalableMapping_get(actor3),
          bn(250).mul(totalAmount).div(bn(450))
        );
      });
    });

    describe('another actor enters with value', async () => {
      const actor4 = distUtils.getActor('4');
      const actor4Value = wei(500);
      before('add value', async () => {
        await FakeScalableMapping.ScalableMapping_set(actor4, actor4Value.toBN());
      });

      it('has correct total amount', async () => {
        const totalAmount = await FakeScalableMapping.ScalableMapping_totalAmount();
        assertBn.near(totalAmount, bn(1950), 1);
      });
    });

    describe('actor exits', async () => {
      before('remove value', async () => {
        await FakeScalableMapping.ScalableMapping_set(actor1, 0);
      });

      it('has correct total amount', async () => {
        const totalAmount = await FakeScalableMapping.ScalableMapping_totalAmount();
        assertBn.near(totalAmount, bn(1900), 1);
      });
    });

    describe('large negative value', async () => {
      it('reverts', async () => {
        await assertRevert(
          FakeScalableMapping.ScalableMapping_scale(wei(-1, 27).toBN()),
          'InsufficientMappedAmount'
        );
      });
    });

    describe('large value add', async () => {
      before('add one actor with normal value', async () => {
        await FakeScalableMapping.ScalableMapping_set(actor1, bn(10));
      });

      it('does not allow to add value that would overflow', async () => {
        await assertRevert(
          FakeScalableMapping.ScalableMapping_scale(bn(1e18)),
          'OverflowInt256ToInt128'
        );
      });
    });
  });

  // some edge cases tested above.
  describe('edge case scenarios', async () => {
    before(restore);

    describe('when actor gets set with large value', async () => {
      before('add value', async () => {
        await FakeScalableMapping.ScalableMapping_set(actor1, bn(5));
        await FakeScalableMapping.ScalableMapping_set(actor2, bn(5e18));
      });

      before('scale value', async () => {
        await FakeScalableMapping.ScalableMapping_scale(bn(500));
      });

      it('has correct total amount', async () => {
        const totalShares = bn(5).add(bn(5e18));
        // use high precision to avoid rounding errors when asserting
        const scalar = bn(500).mul(hp).div(totalShares);
        const totalAmount = scalar.add(hp).mul(totalShares).div(hp);

        assertBn.equal(await FakeScalableMapping.ScalableMapping_totalAmount(), totalAmount);
      });
    });
  });
});