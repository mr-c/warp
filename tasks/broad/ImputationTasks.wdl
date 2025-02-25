version 1.0

task CalculateChromosomeLength {
  input {
    File ref_dict
    Int chrom

    String ubuntu_docker = "ubuntu:20.04"
    Int memory_mb = 2000
    Int cpu = 1
    Int disk_size_gb = ceil(2*size(ref_dict, "GiB")) + 5
  }

  command {
    grep -P "SN:~{chrom}\t" ~{ref_dict} | sed 's/.*LN://' | sed 's/\t.*//'
  }
  runtime {
    docker: ubuntu_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    Int chrom_length = read_int(stdout())
  }
}

task GenerateChunk {
  input {
    Int start
    Int end
    String chrom
    String basename
    String vcf
    String vcf_index

    Int disk_size_gb = ceil(2*size(vcf, "GiB")) + 50 # not sure how big the disk size needs to be since we aren't downloading the entire VCF here
    Int cpu = 1
    Int memory_mb = 8000
    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
  }
  command {
    gatk SelectVariants \
    -V ~{vcf} \
    --select-type-to-include SNP \
    --max-nocall-fraction 0.1 \
    -xl-select-type SYMBOLIC \
    --select-type-to-exclude MIXED \
    --restrict-alleles-to BIALLELIC \
    -L ~{chrom}:~{start}-~{end} \
    -O ~{basename}.vcf.gz \
    --exclude-filtered true
  }
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  parameter_meta {
    vcf: {
      description: "vcf",
      localization_optional: true
    }
    vcf_index: {
      description: "vcf index",
      localization_optional: true
    }
  }
  output {
    File output_vcf = "~{basename}.vcf.gz"
    File output_vcf_index = "~{basename}.vcf.gz.tbi"
  }
}

task CountVariantsInChunks {
  input {
    File vcf
    File vcf_index
    File panel_vcf
    File panel_vcf_index

    Int disk_size_gb = ceil(2*size([vcf, vcf_index, panel_vcf, panel_vcf_index], "GiB"))
    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 4000
  }
  command <<<
    echo $(gatk CountVariants -V ~{vcf}  | sed 's/Tool returned://') > var_in_original
    echo $(gatk  CountVariants -V ~{vcf} -L ~{panel_vcf}  | sed 's/Tool returned://') > var_in_reference
  >>>
  output {
    Int var_in_original = read_int("var_in_original")
    Int var_in_reference = read_int("var_in_reference")
  }
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task CheckChunks {
  input {
    File vcf
    File vcf_index
    File panel_vcf
    File panel_vcf_index
    Int var_in_original
    Int var_in_reference

    Int disk_size_gb = ceil(2*size([vcf, vcf_index, panel_vcf, panel_vcf_index], "GiB"))
    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 4000
  }
  command <<<
    if [ $(( ~{var_in_reference} * 2 - ~{var_in_original})) -gt 0 ] && [ ~{var_in_reference} -gt 3 ]; then
      echo true > valid_file.txt
    else
      echo false > valid_file.txt
    fi

    bcftools convert -Ob ~{vcf} > valid_variants.bcf
    bcftools index -f valid_variants.bcf
  >>>
  output {
    File valid_chunk_bcf = "valid_variants.bcf"
    File valid_chunk_bcf_index = "valid_variants.bcf.csi"
    Boolean valid = read_boolean("valid_file.txt")
  }
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task PhaseVariantsEagle {
  input {
    File dataset_bcf
    File dataset_bcf_index
    File reference_panel_bcf
    File reference_panel_bcf_index
    String chrom
    File genetic_map_file
    Int start
    Int end

    String eagle_docker = "us.gcr.io/broad-gotc-prod/imputation-eagle:1.0.0-2.4-1633695564"
    Int cpu = 8
    Int memory_mb = 32000
    Int disk_size_gb = ceil(3 * size([dataset_bcf, reference_panel_bcf, dataset_bcf_index, reference_panel_bcf_index], "GiB"))
  }
  command <<<
    /usr/gitc/eagle  \
    --vcfTarget ~{dataset_bcf}  \
    --vcfRef ~{reference_panel_bcf} \
    --geneticMapFile ~{genetic_map_file} \
    --outPrefix pre_phased_~{chrom} \
    --vcfOutFormat z \
    --bpStart ~{start} \
    --bpEnd ~{end} \
    --allowRefAltSwap
  >>>
  output {
    File dataset_prephased_vcf="pre_phased_~{chrom}.vcf.gz"
  }
  runtime {
    docker: eagle_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task Minimac4 {
  input {
    File ref_panel
    File phased_vcf
    String prefix
    String chrom
    Int start
    Int end
    Int window

    String minimac4_docker = "us.gcr.io/broad-gotc-prod/imputation-minimac4:1.0.0-1.0.2-1633700284"
    Int cpu = 1
    Int memory_mb = 4000
    Int disk_size_gb = ceil(size(ref_panel, "GiB") + 2*size(phased_vcf, "GiB")) + 50
  }
  command <<<
    /usr/gitc/minimac4 \
    --refHaps ~{ref_panel} \
    --haps ~{phased_vcf} \
    --start ~{start} \
    --end ~{end} \
    --window ~{window} \
    --chr ~{chrom} \
    --noPhoneHome \
    --format GT,DS,GP \
    --allTypedSites \
    --prefix ~{prefix} \
    --minRatio 0.00001

    bcftools index -t ~{prefix}.dose.vcf.gz
  >>>
  output {
    File vcf = "~{prefix}.dose.vcf.gz"
    File vcf_index = "~{prefix}.dose.vcf.gz.tbi"
    File info = "~{prefix}.info"
  }
  runtime {
    docker: minimac4_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task GatherVcfs {
  input {
    Array[File] input_vcfs
    Array[File] input_vcf_indices
    String output_vcf_basename

    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 16000
    Int disk_size_gb = ceil(3*size(input_vcfs, "GiB"))
  }
  command <<<
    gatk GatherVcfs \
    -I ~{sep=' -I ' input_vcfs} \
    -O ~{output_vcf_basename}.vcf.gz

    gatk IndexFeatureFile -I ~{output_vcf_basename}.vcf.gz

  >>>
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{output_vcf_basename}.vcf.gz"
    File output_vcf_index = "~{output_vcf_basename}.vcf.gz.tbi"
  }
}

task UpdateHeader {
  input {
    File vcf
    File vcf_index
    File ref_dict
    String basename

    Int disk_size_gb = ceil(4*(size(vcf, "GiB") + size(vcf_index, "GiB"))) + 20
    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 8000
  }
  command <<<

    ## update the header of the merged vcf
    gatk UpdateVCFSequenceDictionary \
    --source-dictionary ~{ref_dict} \
    --output ~{basename}.vcf.gz \
    --replace -V ~{vcf} \
    --disable-sequence-dictionary-validation
  >>>
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{basename}.vcf.gz"
    File output_vcf_index = "~{basename}.vcf.gz.tbi"
  }
}

task RemoveSymbolicAlleles {
  input {
    File original_vcf
    File original_vcf_index
    String output_basename

    Int disk_size_gb = ceil(3*(size(original_vcf, "GiB") + size(original_vcf_index, "GiB")))
    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 4000
  }
  command {
    gatk SelectVariants -V ~{original_vcf} -xl-select-type SYMBOLIC -O ~{output_basename}.vcf.gz
  }
  output {
    File output_vcf = "~{output_basename}.vcf.gz"
    File output_vcf_index = "~{output_basename}.vcf.gz.tbi"
  }
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task SeparateMultiallelics {
  input {
    File original_vcf
    File original_vcf_index
    String output_basename

    Int disk_size_gb =  ceil(2*(size(original_vcf, "GiB") + size(original_vcf_index, "GiB")))
    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 4000
  }
  command {
    bcftools norm -m - ~{original_vcf} -Oz -o ~{output_basename}.vcf.gz
    bcftools index -t ~{output_basename}.vcf.gz
  }
  output {
    File output_vcf = "~{output_basename}.vcf.gz"
    File output_vcf_index = "~{output_basename}.vcf.gz.tbi"
  }
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task OptionalQCSites {
  input {
    File input_vcf
    File input_vcf_index
    String output_vcf_basename
    Float? optional_qc_max_missing
    Float? optional_qc_hwe

    String bcftools_vcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 16000
    Int disk_size_gb = ceil(2*(size(input_vcf, "GiB") + size(input_vcf_index, "GiB")))

  }
  Float max_missing = select_first([optional_qc_max_missing, 0.05])
  Float hwe = select_first([optional_qc_hwe, 0.000001])
  command <<<
    # site missing rate < 5% ; hwe p > 1e-6
    vcftools --gzvcf ~{input_vcf}  --max-missing ~{max_missing} --hwe ~{hwe} --recode -c | bgzip -c > ~{output_vcf_basename}.vcf.gz
    bcftools index -t ~{output_vcf_basename}.vcf.gz # Note: this is necessary because vcftools doesn't have a way to output a zipped vcf, nor a way to index one (hence needing to use bcf).
  >>>
  runtime {
    docker: bcftools_vcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{output_vcf_basename}.vcf.gz"
    File output_vcf_index = "~{output_vcf_basename}.vcf.gz.tbi"
  }
}

task MergeSingleSampleVcfs {
  input {
    Array[File] input_vcfs
    Array[File] input_vcf_indices
    String output_vcf_basename

    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int memory_mb = 2000
    Int cpu = 1
    Int disk_size_gb = 3 * ceil(size(input_vcfs, "GiB") + size(input_vcf_indices, "GiB")) + 20
  }
  command <<<
    bcftools merge ~{sep=' ' input_vcfs} -O z -o ~{output_vcf_basename}.vcf.gz
    bcftools index -t ~{output_vcf_basename}.vcf.gz
  >>>
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{output_vcf_basename}.vcf.gz"
    File output_vcf_index = "~{output_vcf_basename}.vcf.gz.tbi"
  }
}

task CountSamples {
  input {
    File vcf

    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 3000
    Int disk_size_gb = 100 + ceil(size(vcf, "GiB"))
  }
  command <<<
    bcftools query -l ~{vcf} | wc -l
  >>>
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    Int nSamples = read_int(stdout())
  }
}

task AggregateImputationQCMetrics {
  input {
    File infoFile
    Int nSamples
    String basename

    String rtidyverse_docker = "rocker/tidyverse:4.1.0"
    Int cpu = 1
    Int memory_mb = 2000
    Int disk_size_gb = 100 + ceil(size(infoFile, "GiB"))
  }
  command <<<
    Rscript -<< "EOF"
    library(dplyr)
    library(readr)
    library(purrr)
    library(ggplot2)

    sites_info <- read_tsv("~{infoFile}")

    nSites <- sites_info %>% nrow()
    nSites_with_var <- sites_info %>% filter(MAF >= 0.3/(2*~{nSamples} - 0.7)) %>% nrow()
    nSites_high_r2 <- sites_info %>% filter(Rsq>0.3) %>% nrow()

    aggregated_metrics <- tibble(total_sites=nSites, total_sites_with_var=nSites_with_var, total_sites_r2_gt_0.3=nSites_high_r2,)

    write_tsv(aggregated_metrics, "~{basename}_aggregated_imputation_metrics.tsv")

    EOF
  >>>
  runtime {
    docker: rtidyverse_docker
    disks : "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
    preemptible : 3
  }
  output {
    File aggregated_metrics = "~{basename}_aggregated_imputation_metrics.tsv"
  }
}

task StoreChunksInfo {
  input {
    Array[String] chroms
    Array[Int] starts
    Array[Int] ends
    Array[Int] vars_in_array
    Array[Int] vars_in_panel
    Array[Boolean] valids
    String basename

    String rtidyverse_docker = "rocker/tidyverse:4.1.0"
    Int cpu = 1
    Int memory_mb = 2000
    Int disk_size_gb = 10
  }
  command <<<
    Rscript -<< "EOF"
    library(dplyr)
    library(readr)

    chunk_info <- tibble(chrom = c("~{sep='", "' chroms}"), start = c("~{sep='", "' starts}"), ends = c("~{sep='", "' ends}"), vars_in_array = c("~{sep='", "' vars_in_array}"), vars_in_panel = c("~{sep='", "' vars_in_panel}"), chunk_was_imputed = as.logical(c("~{sep='", "' valids}")))
    failed_chunks <- chunk_info %>% filter(!chunk_was_imputed) %>% select(-chunk_was_imputed)
    n_failed_chunks <- nrow(failed_chunks)
    write_tsv(chunk_info, "~{basename}_chunk_info.tsv")
    write_tsv(failed_chunks, "~{basename}_failed_chunks.tsv")
    write(n_failed_chunks, "n_failed_chunks.txt")
    EOF
  >>>
  runtime {
    docker: rtidyverse_docker
    disks : "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
    preemptible : 3
  }
  output {
    File chunks_info = "~{basename}_chunk_info.tsv"
    File failed_chunks = "~{basename}_failed_chunks.tsv"
    File n_failed_chunks = "n_failed_chunks.txt"
  }
}

task MergeImputationQCMetrics {
  input {
    Array[File] metrics
    String basename

    String rtidyverse_docker = "rocker/tidyverse:4.1.0"
    Int cpu = 1
    Int memory_mb = 2000
    Int disk_size_gb = 100 + ceil(size(metrics, "GiB"))
  }
  command <<<
    Rscript -<< "EOF"
    library(dplyr)
    library(readr)
    library(purrr)
    library(ggplot2)

    metrics <- list("~{sep='", "' metrics}") %>% map(read_tsv) %>% reduce(`+`) %>% mutate(frac_sites_r2_gt_0.3=total_sites_r2_gt_0.3/total_sites, frac_sites_with_var_r2_gt_0.3=total_sites_r2_gt_0.3/total_sites_with_var)

    write_tsv(metrics, "~{basename}_aggregated_imputation_metrics.tsv")
    write(metrics %>% pull(frac_sites_with_var_r2_gt_0.3), "frac_well_imputed.txt")

    EOF
  >>>
  runtime {
    docker: rtidyverse_docker
    disks : "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
    preemptible : 3
  }
  output {
    File aggregated_metrics = "~{basename}_aggregated_imputation_metrics.tsv"
    Float frac_well_imputed = read_float("frac_well_imputed.txt")
  }
}

task SetIDs {
  input {
    File vcf
    String output_basename

    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 4000
    Int disk_size_gb = 100 + ceil(2.2 * size(vcf, "GiB"))
  }
  command <<<
    bcftools annotate ~{vcf} --set-id '%CHROM\:%POS\:%REF\:%FIRST_ALT' -Ov | \
      awk -v OFS='\t' '{split($3, n, ":"); if ( !($1 ~ /^"#"/) && n[4] < n[3])  $3=n[1]":"n[2]":"n[4]":"n[3]; print $0}' | \
      bgzip -c > ~{output_basename}.vcf.gz

    bcftools index -t ~{output_basename}.vcf.gz
  >>>
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{output_basename}.vcf.gz"
    File output_vcf_index = "~{output_basename}.vcf.gz.tbi"
  }
}

task ExtractIDs {
  input {
    File vcf
    String output_basename

    Int disk_size_gb = 2*ceil(size(vcf, "GiB")) + 100
    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 4000
  }
  command <<<
    bcftools query -f "%ID\n" ~{vcf} -o ~{output_basename}.ids.txt
  >>>
  output {
    File ids = "~{output_basename}.ids.txt"
  }
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
}

task SelectVariantsByIds {
  input {
    File vcf
    File ids
    String basename

    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 16000
    Int disk_size_gb = ceil(1.2*size(vcf, "GiB")) + 100
  }
  parameter_meta {
    vcf: {
      description: "vcf",
      localization_optional: true
    }
  }
  command <<<
    cp ~{ids} sites.list
    gatk SelectVariants -V ~{vcf} --exclude-filtered --keep-ids sites.list -O ~{basename}.vcf.gz
  >>>
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} SSD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{basename}.vcf.gz"
    File output_vcf_index = "~{basename}.vcf.gz.tbi"
  }
}

task RemoveAnnotations {
  input {
    File vcf
    String basename

    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 3000
    Int disk_size_gb = ceil(2.2*size(vcf, "GiB")) + 100
  }
  command <<<
    bcftools annotate ~{vcf} -x FORMAT,INFO -Oz -o ~{basename}.vcf.gz
    bcftools index -t ~{basename}.vcf.gz
  >>>
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{basename}.vcf.gz"
    File output_vcf_index = "~{basename}.vcf.gz.tbi"
  }
}

task InterleaveVariants {
  input {
    Array[File] vcfs
    String basename

    String gatk_docker = "us.gcr.io/broad-gatk/gatk:4.1.9.0"
    Int cpu = 1
    Int memory_mb = 16000
    Int disk_size_gb = ceil(3.2*size(vcfs, "GiB")) + 100
  }
  command <<<
    gatk MergeVcfs -I ~{sep=" -I " vcfs} -O ~{basename}.vcf.gz
  >>>
  runtime {
    docker: gatk_docker
    disks: "local-disk ${disk_size_gb} SSD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File output_vcf = "~{basename}.vcf.gz"
    File output_vcf_index = "~{basename}.vcf.gz.tbi"
  }
}

task FindSitesUniqueToFileTwoOnly {
  input {
    File file1
    File file2

    String ubuntu_docker = "ubuntu:20.04"
    Int cpu = 1
    Int memory_mb = 4000
    Int disk_size_gb = ceil(size(file1, "GiB") + 2*size(file2, "GiB")) + 100
  }
  command <<<
    comm -13 <(sort ~{file1} | uniq) <(sort ~{file2} | uniq) > missing_sites.ids
  >>>
  runtime {
    docker: ubuntu_docker
    disks: "local-disk ${disk_size_gb} HDD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    File missing_sites = "missing_sites.ids"
  }
}

task SplitMultiSampleVcf {
 input {
    File multiSampleVcf

    String bcftools_docker = "us.gcr.io/broad-gotc-prod/imputation-bcf-vcf:1.0.0-1.10.2-0.1.16-1633627919"
    Int cpu = 1
    Int memory_mb = 8000
    Int disk_size_gb = ceil(3*size(multiSampleVcf, "GiB")) + 100
  }
  command <<<
    mkdir out_dir
    bcftools +split ~{multiSampleVcf} -Oz -o out_dir
    for vcf in out_dir/*.vcf.gz; do
      bcftools index -t $vcf
    done
  >>>
  runtime {
    docker: bcftools_docker
    disks: "local-disk ${disk_size_gb} SSD"
    memory: "${memory_mb} MiB"
    cpu: cpu
  }
  output {
    Array[File] single_sample_vcfs = glob("out_dir/*.vcf.gz")
    Array[File] single_sample_vcf_indices = glob("out_dir/*.vcf.gz.tbi")
  }
}