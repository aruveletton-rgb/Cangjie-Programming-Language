export function scoreAt5(gold, evidenceRefs) {
  const ids = evidenceRefs.map(x => x.evidenceId);
  const top5Ids = ids.slice(0, 5);
  const hits = gold.filter(x => top5Ids.includes(x)).length;
  return {
    ids,
    top5Ids,
    recallAt5: gold.length ? hits / gold.length : null,
    hitAt5: gold.length ? hits > 0 : null,
    correctNoEvidence: gold.length ? null : ids.length === 0
  };
}

export function inspectGatewayMetadata(data) {
  const gatewayMode = data?.gatewayMode;
  const realG1Ran = data?.realG1Ran;
  if (!['G0', 'MOCK', 'G1'].includes(gatewayMode)) {
    return { valid: false, error: 'gatewayMode is missing or unsupported', gatewayMode: gatewayMode ?? null, realG1Ran: realG1Ran ?? null };
  }
  if (typeof realG1Ran !== 'boolean') {
    return { valid: false, error: 'realG1Ran is missing or not boolean', gatewayMode, realG1Ran: realG1Ran ?? null };
  }
  if ((gatewayMode === 'G1') !== realG1Ran) {
    return { valid: false, error: 'gatewayMode and realG1Ran contradict each other', gatewayMode, realG1Ran };
  }
  return { valid: true, error: null, gatewayMode, realG1Ran };
}

// Response metadata describes what the endpoint reports; it does not prove provider execution.
export function summarizeGatewayExecution(results) {
  const reportedG1CallCount=results.filter(x=>x.callStatus==='succeeded'&&x.gatewayMetadataValid&&x.gatewayMode==='G1'&&x.realG1Ran===true).length;
  const complete=results.length>0&&results.every(x=>x.callStatus==='succeeded'&&x.gatewayMetadataValid);
  return {
    reportedG1CallCount,
    realG1CallCount:reportedG1CallCount||!complete?null:0,
    g1:{
      status:reportedG1CallCount?'observed_unverified':complete?'not_run':'unknown',
      reason:reportedG1CallCount?'Successful responses report G1 execution; provider execution is not independently verified.':complete?'All evaluated successful responses have valid metadata and report no G1 execution.':'Failed calls or invalid metadata prevent a complete execution summary.',
      metadataCoverageComplete:complete,
      providerVerification:'not_performed'
    }
  };
}
