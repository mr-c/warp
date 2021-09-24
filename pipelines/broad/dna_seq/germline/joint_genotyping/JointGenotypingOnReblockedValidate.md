It is expected that some variants will have annotation changes:
- New version has higher ANs in some cases -- low quality genotypes retain more data
- When ANs vary, DP can obviously vary, 
- ACs may not agree for * alleles because of corrections in reblocking
- InbreedingCoeff (and AS_InbreedingCoeff) can vary since it's likelihood-based and not count based like ExcessHet; this is especially noticeable at low GQs because likelihood is split more evenly across genotypes
- RankSums can vary because of a histogram/median bug fix in PR #7131 implemented in versions 4.2.1.0 and subsequent
- High QD values can vary because of the "correction" of remapping values > 35 back to a Gaussian centered at 30 (stdev 3); may also vary because of DP differences?

Spanning deletion alleles may be missing in new output due to corrections in reblocking (--allow-missing-stars)
In a few rare cases variants appear to be "dropped" in the reblocked output (this is the --allow-extra-alleles argument below)
QUAL scores are highly sensitive to a variety of factors including CPU platform, but here they may vary more significantly because GQ0 genotypes with depth data are called as hom-refs

The GATK branch ldg_VCFcomparator (4f0292abaeb7cabb527ca830048520e8aecdbde4) can take into account a lot of these
 expected differences with a command like:
 java -jar gatk.compare.jar VCFComparator -V:expected $truth -V:actual $test  --ignore-quals -R $hg38 --warn-on-errors \
 --allow-extra-alleles --allow-missing-stars  --ignore-filters --ignore-attribute DP --ignore-attribute VQSLOD --ignore-attribute culprit

Lots of warnings about AN or InbreedingCoeff mismatches, but only exceptions that output VCs are of concern

Exome tests needed VQSR indel Gaussians reduced to 3 (only 50 exomes -- not a lot of indels; --ignore-filters --ignore-attribute VQSLOD --ignore-attribute culprit)