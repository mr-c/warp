version 1.0

import "../../../../../../tasks/broad/GermlineVariantDiscovery.wdl" as Calling
import "../../../../../../tasks/broad/Qc.wdl" as QC

workflow ReblockGVCF {

  String pipeline_version = "2.0.0"

  input {
    File gvcf
    File gvcf_index
    File? calling_interval_list
    File ref_dict
    File ref_fasta
    File ref_fasta_index
  }

  String gvcf_basename = basename(gvcf, ".g.vcf.gz")

  call Calling.Reblock as Reblock {
    input:
      gvcf = gvcf,
      gvcf_index = gvcf_index,
      ref_fasta = ref_fasta,
      ref_fasta_index = ref_fasta_index,
      ref_dict = ref_dict,
      output_vcf_filename = gvcf_basename + ".rb.g.vcf.gz"
  }

    # Validate the (g)VCF output of HaplotypeCaller
    call QC.ValidateVCF as ValidateVCF {
      input:
        input_vcf = Reblock.output_vcf,
        input_vcf_index = Reblock.output_vcf_index,
        ref_fasta = ref_fasta,
        ref_fasta_index = ref_fasta_index,
        ref_dict = ref_dict,
        calling_interval_list = select_first([calling_interval_list, gvcf]), #nice trick so we don't have to pass around intervals; shouldn't be too much slower
        calling_interval_list_index = gvcf_index,
        is_gvcf = true,
        extra_args = "--no-overlaps",
        gatk_docker = "us.gcr.io/broad-dsde-methods/validate_reblocking@sha256:ede2cae0d345c6ad2690db99d1d6485adc2b52f98deb5e821bd64baf3df63602"
    }

  output {
    File output_vcf = Reblock.output_vcf
    File output_vcf_index = Reblock.output_vcf_index
  }
  meta {
    allowNestedInputs: true
  }
}

task Reblock {

  input {
    File gvcf
    File gvcf_index

    File ref_fasta
    File ref_fasta_index
    File ref_dict

    String output_vcf_filename
    String docker_image = "us.gcr.io/broad-gatk/gatk:4.2.2.0"
  }

  Int disk_size = ceil(size(gvcf, "GiB")) * 2 + 3

  command {
    gatk --java-options "-Xms3g -Xmx3g" \
      ReblockGVCF \
      -R ~{ref_fasta} \
      -V ~{gvcf} \
      -do-qual-approx \
      --floor-blocks -GQB 20 -GQB 30 -GQB 40 \
      -O ~{output_vcf_filename}
  }

  runtime {
    memory: "3.75 GB"
    bootDiskSizeGb: "15"
    disks: "local-disk " + disk_size + " HDD"
    preemptible: 3
    docker: docker_image
  }

  output {
    File output_vcf = output_vcf_filename
    File output_vcf_index = output_vcf_filename + ".tbi"
  }
} 
