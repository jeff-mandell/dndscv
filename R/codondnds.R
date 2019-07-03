#' codondnds
#'
#' Function to estimate codon-wise dN/dS values and p-values against neutrality. To generate a valid RefCDS input object for this function, use the buildcodon function. This function is in testing, please interpret the results with caution. Also note that recurrent artefacts or SNP contamination can violate the null model and dominate the list of sites under apparent selection. Be very critical of the results and if suspicious sites appear recurrently mutated consider refining the variant calling (e.g. using a better unmatched normal panel).
#'
#' @author Inigo Martincorena (Wellcome Sanger Institute)
#' 
#' @param dndsout Output object from dndscv.
#' @param refcds RefCDS object annotated with codon-level information using the buildcodon function.
#' @param min_recurr Minimum number of mutations per site to estimate codon-wise dN/dS ratios. [default=2]
#' @param gene_list List of genes to restrict the analysis (only needed if the user wants to restrict the analysis to a subset of the genes in dndsout) [default=NULL, codondnds will be run on all genes in dndsout]
#' @param theta_option 2 options: "mle" (uses the MLE of the negative binomial size parameter) or "conservative" (uses the lower bound of the CI95). Values other than "mle" will lead to the conservative option. [default="mle"]
#' @param syn_drivers Vector with a list of known synonymous driver mutations to exclude from the background model [default="TP53:T125T"]. See Martincorena et al., Cell, 2017 (PMID:29056346).
#'
#' @return 'codondnds' returns a table of recurrently mutated codons and the estimates of the size parameter:
#' @return - recurcodons: Table of recurrently mutated codons with codon-wise dN/dS values and p-values
#' @return - recurcodons_ext: The same table of recurrently mutated codons, but including additional information on the contribution of different changes within a codon.
#' @return - theta: Maximum likelihood estimate and CI95% for the size parameter of the negative binomial distribution. The lower this value the higher the variation of the mutation rate across sites not captured by the trinucleotide change or by variation across genes.
#' 
#' @export

codondnds = function(dndsout, refcds, min_recurr = 2, gene_list = NULL, theta_option = "mle", syn_drivers = "TP53:T125T") {
    
    ## 1. Fitting a negative binomial distribution at the site level considering the background mutation rate of the gene and of each trinucleotide
    message("[1] Codon-wise negative binomial model accounting for trinucleotides and relative gene mutability...")
    
    if (nrow(dndsout$mle_submodel)!=195) { stop("Invalid input: dndsout must be generated using the default trinucleotide substitution model in dndscv.") }
    if (is.null(refcds[[1]]$codon_impact)) { stop("Invalid input: the input RefCDS object must contain codon-level annotation. Use the buildcodon function to add this information.") }
    
    # Restricting the analysis to an input list of genes
    if (!is.null(gene_list)) {
        g = as.vector(dndsout$genemuts$gene_name)
        nonex = gene_list[!(gene_list %in% g)]
        if (length(nonex)>0) {
            warning(sprintf("The following input gene names are not in dndsout input object and will not be analysed: %s.", paste(nonex,collapse=", ")))
        }
        dndsout$annotmuts = dndsout$annotmuts[which(dndsout$annotmuts$gene %in% gene_list), ]
        dndsout$genemuts = dndsout$genemuts[which(g %in% gene_list), ]
        refcds = refcds[sapply(refcds, function(x) x$gene_name) %in% gene_list] # Only input genes
    }
    
    # Relative mutation rate per gene
    # Note that this assumes that the gene order in genemuts has not been altered with respect to the N and L matrices, as it is currently the case in dndscv
    relmr = dndsout$genemuts$exp_syn_cv/dndsout$genemuts$exp_syn
    names(relmr) = dndsout$genemuts$gene_name
    
    # Substitution rates (192 trinucleotide rates, strand-specific)
    sm = setNames(dndsout$mle_submodel$mle, dndsout$mle_submodel$name)
    sm["TTT>TGT"] = 1 # Adding the TTT>TGT rate (which is arbitrarily set to 1 relative to t)
    sm = sm*sm["t"] # Absolute rates
    sm = sm[setdiff(names(sm),c("wmis","wnon","wspl","t"))] # Removing selection parameters
    sm = sm[order(names(sm))] # Sorting
    
    # Annotated mutations per gene
    annotsubs = dndsout$annotmuts[which(dndsout$annotmuts$impact=="Synonymous"),]
    annotsubs = annotsubs[!(paste(annotsubs$gene,annotsubs$aachange,sep=":") %in% syn_drivers),]
    annotsubs$codon = as.numeric(substr(annotsubs$aachange,2,nchar(annotsubs$aachange)-1)) # Numeric codon position
    annotsubs = split(annotsubs, f=annotsubs$gene)
    
    # Calculating observed and expected mutation rates per codon for every gene
    numcodons = sum(sapply(refcds, function(x) x$CDS_length))/3 # Number of codons in the genes of interest
    nvec = rvec = array(NA, numcodons)
    pos = 1
    
    for (j in 1:length(refcds)) {
        
        nvec_syn = rvec_syn = rvec_ns = array(0,refcds[[j]]$CDS_length/3) # Initialising the obs and exp vectors
        gene = refcds[[j]]$gene_name
        sm_rel = sm * relmr[gene]
        
        # Expected rates
        ind = rep(1:(refcds[[j]]$CDS_length/3), each=9)
        syn = which(refcds[[j]]$codon_impact==1) # Synonymous changes
        ns = which(refcds[[j]]$codon_impact %in% c(2,3)) # Missense and nonsense changes
        
        aux = sapply(split(refcds[[j]]$codon_rates[syn], f=ind[syn]), function(x) sum(sm_rel[x]))
        rvec_syn[as.numeric(names(aux))] = aux
        
        aux = sapply(split(refcds[[j]]$codon_rates[ns], f=ind[ns]), function(x) sum(sm_rel[x]))
        rvec_ns[as.numeric(names(aux))] = aux
        
        # Observed mutations
        subs = annotsubs[[gene]]
        if (!is.null(subs)) {
            obs_syn = table(subs$codon)
            nvec_syn[as.numeric(names(obs_syn))] = obs_syn
        }
        
        rvec[pos:(pos+refcds[[j]]$CDS_length/3-1)] = rvec_syn
        nvec[pos:(pos+refcds[[j]]$CDS_length/3-1)] = nvec_syn
        pos = pos + refcds[[j]]$CDS_length/3
        
        refcds[[j]]$codon_rvec_ns = rvec_ns
        
        if (round(j/2000)==(j/2000)) { message(sprintf('    %0.3g%% ...', round(j/length(refcds),2)*100)) }
    }
    
    rvec = rvec * sum(nvec) / sum(rvec) # Small correction ensuring that global observed and expected rates are identical
    
    
    message("[2] Estimating overdispersion and calculating site-wise dN/dS ratios...")
    
    # Estimation of overdispersion modelling rates per codon as negative binomially distributed (i.e. quantifying uncertainty above Poisson using a Gamma) 
    # Using optimize appears to yield reliable results. Problems experienced with fitdistr, glm.nb and theta.ml. Consider using grid search if problems appear with optimize.
    nbin = function(theta, n=nvec, r=rvec) { -sum(dnbinom(x=n, mu=r, log=T, size=theta)) } # nbin loglik function for optimisation
    ml = optimize(nbin, interval=c(0,1000))
    theta_ml = ml$minimum
    
    # CI95% for theta using profile likelihood and iterative grid search (this yields slightly conservative CI95)
    
    grid_proflik = function(bins=5, iter=5) {
        for (j in 1:iter) {
            if (j==1) {
                thetavec = sort(c(0, 10^seq(-3,3,length.out=bins), theta_ml, theta_ml*10, 1e4)) # Initial vals
            } else {
                thetavec = sort(c(seq(thetavec[ind[1]], thetavec[ind[1]+1], length.out=bins), seq(thetavec[ind[2]-1], thetavec[ind[2]], length.out=bins))) # Refining previous iteration
            }
            
            proflik = sapply(thetavec, function(theta) -sum(dnbinom(x=nvec, mu=rvec, size=theta, log=T))-ml$objective) < qchisq(.95,1)/2 # Values of theta within CI95%
            ind = c(which(proflik[1:(length(proflik)-1)]==F & proflik[2:length(proflik)]==T)[1],
                    which(proflik[1:(length(proflik)-1)]==T & proflik[2:length(proflik)]==F)[1]+1)
            if (is.na(ind[1])) { ind[1] = 1 }
            if (is.na(ind[2])) { ind[2] = length(thetavec) }
        }
        return(thetavec[ind])
    }
    
    theta_ci95 = grid_proflik(bins=5, iter=5)
    
    
    ## 2. Calculating site-wise dN/dS ratios and P-values for recurrently mutated sites (P-values are based on the Gamma assumption underlying the negative binomial modelling)
    
    # Counts of observed nonsynonymous mutations
    annotsubs = dndsout$annotmuts[which(dndsout$annotmuts$impact %in% c("Missense","Nonsense")),]
    annotsubs$codon = substr(annotsubs$aachange,1,nchar(annotsubs$aachange)-1) # Codon position
    annotsubs$codonsub = paste(annotsubs$chr,annotsubs$gene,annotsubs$codon,sep=":")
    annotsubs = annotsubs[which(annotsubs$ref!=annotsubs$mut),]
    freqs = sort(table(annotsubs$codonsub), decreasing=T)
    freqs = freqs[freqs>=min_recurr]
    
    if (theta_option=="mle") {
        theta = theta_ml
    } else { # Conservative
        theta = theta_ci95[1]
    }
    thetaout = setNames(c(theta_ml, theta_ci95), c("MLE","CI95low","CI95_high"))
    
    if (length(freqs)>1) {
    
        recurcodons = read.table(text=names(freqs), header=0, sep=":", stringsAsFactors=F) # Frequency table of mutations
        colnames(recurcodons) = c("chr","gene","codon")
        recurcodons$freq = freqs
        recurcodons$mu = NA
        
        codonnumeric = as.numeric(substr(recurcodons$codon,2,nchar(recurcodons$codon))) # Numeric codon position
        geneind = setNames(1:length(refcds), sapply(refcds, function(x) x$gene_name))
    
        for (j in 1:nrow(recurcodons)) {
            recurcodons$mu[j] = refcds[[geneind[recurcodons$gene[j]]]]$codon_rvec_ns[codonnumeric[j]] # Background non-synonymous rate for this codon
        }
        
        recurcodons$dnds = recurcodons$freq / recurcodons$mu # Codon-wise dN/dS (point estimate)
        recurcodons$pval = pnbinom(q=recurcodons$freq-0.5, mu=recurcodons$mu, size=theta, lower.tail=F)
        recurcodons = recurcodons[order(recurcodons$pval, -recurcodons$freq), ] # Sorting by p-val and frequency
        recurcodons$qval = p.adjust(recurcodons$pval, method="BH", n=numcodons) # P-value adjustment for all possible changes
        rownames(recurcodons) = NULL
        
        # Additional annotation
        annotsubs$mutaa = substr(annotsubs$aachange,nchar(annotsubs$aachange),nchar(annotsubs$aachange))
        annotsubs$simplent = paste(annotsubs$ref,annotsubs$mut,sep=">")
        annotsubs$mutnt = paste(annotsubs$chr,annotsubs$pos,annotsubs$simplent,annotsubs$mutaa,sep="_")
        aux = split(annotsubs, f=annotsubs$codonsub)
        recurcodons_ext = recurcodons
        recurcodons_ext$codonsub = paste(recurcodons_ext$chr,recurcodons_ext$gene,recurcodons_ext$codon,sep=":")
        recurcodons_ext$mutnt = recurcodons_ext$mutaa = NA
        for (j in 1:nrow(recurcodons_ext)) {
            x = aux[[recurcodons_ext$codonsub[j]]]
            f = sort(table(x$mutaa),decreasing=T)
            recurcodons_ext$mutaa[j] = paste(names(f),f,sep=":",collapse="|")
            f = sort(table(x$mutnt),decreasing=T)
            recurcodons_ext$mutnt[j] = paste(names(f),f,sep=":",collapse="|")
        }
        
    } else {
        recurcodons = recurcodons_ext = NULL
        warning("No codon was found with the minimum recurrence requested [default min_recurr=2]")
    }
    
    return(list(recurcodons=recurcodons, recurcodons_ext=recurcodons_ext, theta=thetaout))

}